#!/bin/zsh
set -e
ROOT=${0:A:h:h}
cd $ROOT
IDENTITY="Developer ID Application"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" SignDrop/Info.plist)
OUT=$ROOT/build/release
ARCHIVE=$OUT/SignDrop.xcarchive
APP=$OUT/export/SignDrop.app
STAGE=$OUT/dmg
ARCHS="arm64 x86_64"
DMG=$OUT/SignDrop-$VERSION-universal.dmg
LOG=$OUT/build.log
DMG_IDENTIFIER=com.mahmuthanelbir.signdrop.dmg
FAILURES=0

check() {
  if [[ $2 == 1 ]]; then
    print "PASS $1"
  else
    print "FAIL $1 ${3:-}"
    FAILURES=$((FAILURES + 1))
  fi
}

passes() {
  "$@" >/dev/null 2>&1 && print 1 || print 0
}

verify_dmg() {
  local dmg=$1
  check release.dmg.exists $([[ -f $dmg ]] && print 1 || print 0) "$dmg"
  if [[ ! -f $dmg ]]; then
    print "$FAILURES FAILED"
    exit 1
  fi

  local signature=$(codesign -dvv $dmg 2>&1)
  check release.dmg.signed $([[ $signature == *"Authority=$IDENTITY"* && $signature == *"Timestamp="* ]] && print 1 || print 0)
  check release.dmg.identifier $([[ $signature == *"Identifier=$DMG_IDENTIFIER"* ]] && print 1 || print 0)
  check release.dmg.stapled $(passes xcrun stapler validate $dmg)
  local assessment=$(spctl -a -t open --context context:primary-signature -vv $dmg 2>&1)
  check release.dmg.gatekeeper $([[ $assessment == *"accepted"* && $assessment == *"Notarized Developer ID"* ]] && print 1 || print 0) "$assessment"

  local mount=$(mktemp -d -t signdrop-release-check)
  hdiutil attach -nobrowse -readonly -mountpoint $mount $dmg >/dev/null
  local app=$mount/SignDrop.app
  check release.layout.app $([[ -d $app ]] && print 1 || print 0)
  check release.layout.applications $([[ -L $mount/Applications && $(readlink $mount/Applications) == /Applications ]] && print 1 || print 0)
  local app_signature=$(codesign -dvv $app 2>&1)
  check release.app.signed $([[ $app_signature == *"Authority=$IDENTITY"* && $app_signature == *"Timestamp="* ]] && print 1 || print 0)
  check release.app.hardenedRuntime $([[ $app_signature == *"(runtime)"* ]] && print 1 || print 0)
  check release.app.valid $(passes codesign --verify --deep --strict $app)
  local app_assessment=$(spctl -a -t exec -vv $app 2>&1)
  check release.app.gatekeeper $([[ $app_assessment == *"accepted"* && $app_assessment == *"Notarized Developer ID"* ]] && print 1 || print 0) "$app_assessment"
  local app_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $app/Contents/Info.plist 2>/dev/null)
  check release.app.version $([[ $app_version == $VERSION ]] && print 1 || print 0) "$app_version"
  local app_archs=$(lipo -archs $app/Contents/MacOS/SignDrop 2>/dev/null)
  check release.app.universal $([[ ${(j: :)${(o)${(z)app_archs}}} == "$ARCHS" ]] && print 1 || print 0) "$app_archs"
  check release.app.release $([[ -z $(codesign -d --entitlements - --xml $app 2>/dev/null | grep get-task-allow) ]] && print 1 || print 0)
  hdiutil detach $mount -quiet || hdiutil detach $mount -force -quiet || true
  rmdir $mount 2>/dev/null || true

  if [[ $FAILURES != 0 ]]; then
    print "$FAILURES FAILED"
    exit 1
  fi
  print "ALL PASSED"
}

if [[ $1 == --verify ]]; then
  verify_dmg ${2:-$DMG}
  exit 0
fi

if [[ -n $NOTARY_KEY ]]; then
  NOTARY=(--key $NOTARY_KEY --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER)
else
  NOTARY=(--keychain-profile ${NOTARY_PROFILE:-Notarization})
fi

fail() {
  grep -E 'error:' $LOG || tail -20 $LOG
  echo "$1 Full log: $LOG"
  exit 1
}

notarize() {
  echo "Notarizing ${1:t}…"
  local result
  result=$(xcrun notarytool submit $1 $NOTARY --wait --timeout 1h --output-format json) || {
    echo "Could not submit ${1:t} for notarization."
    exit 1
  }
  local submission=$(print -r -- $result | plutil -extract id raw -o - -)
  local notary_status=$(print -r -- $result | plutil -extract status raw -o - -)
  if [[ $notary_status != Accepted ]]; then
    xcrun notarytool log $submission $NOTARY
    echo "Notarization of ${1:t} ended with status: $notary_status"
    exit 1
  fi
}

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "No $IDENTITY certificate in the keychain."
  exit 1
fi
rm -rf $OUT
mkdir -p $STAGE

echo "Archiving SignDrop $VERSION ($ARCHS)…"
xcodebuild -project SignDrop.xcodeproj -scheme SignDrop -configuration Release -archivePath $ARCHIVE archive \
  ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" > $LOG 2>&1 || fail "Archive failed."
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $OUT/export \
  -exportOptionsPlist scripts/ExportOptions.plist >> $LOG 2>&1 || fail "Export failed."

echo "Creating the disk image…"
ditto $APP $STAGE/SignDrop.app
ln -s /Applications $STAGE/Applications
hdiutil create -volname SignDrop -srcfolder $STAGE -ov -format UDZO $DMG >> $LOG 2>&1 || fail "Disk image failed."
codesign --sign "$IDENTITY" --timestamp -i $DMG_IDENTIFIER $DMG
notarize $DMG
xcrun stapler staple $DMG >/dev/null
verify_dmg $DMG
echo "Done: $DMG"
