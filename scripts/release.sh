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
DMG=$OUT/SignDrop-$VERSION.dmg
LOG=$OUT/build.log

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

echo "Archiving SignDrop $VERSION…"
xcodebuild -project SignDrop.xcodeproj -scheme SignDrop -configuration Release -archivePath $ARCHIVE archive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" > $LOG 2>&1 || fail "Archive failed."
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $OUT/export \
  -exportOptionsPlist scripts/ExportOptions.plist >> $LOG 2>&1 || fail "Export failed."

echo "Creating the disk image…"
ditto $APP $STAGE/SignDrop.app
ln -s /Applications $STAGE/Applications
hdiutil create -volname SignDrop -srcfolder $STAGE -ov -format UDZO $DMG >> $LOG 2>&1 || fail "Disk image failed."
codesign --sign "$IDENTITY" --timestamp -i com.mahmuthanelbir.signdrop.dmg $DMG
notarize $DMG
xcrun stapler staple $DMG >/dev/null
echo "Done: $DMG"
