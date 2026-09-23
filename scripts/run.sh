#!/bin/zsh
set -e
ROOT=${0:A:h:h}
cd $ROOT
BUILD=(xcodebuild -workspace SignDrop.xcodeproj/project.xcworkspace -scheme SignDrop -configuration Debug CODE_SIGNING_ALLOWED=NO)
BUILD_LOG=$(mktemp -t signdrop-build)

echo "Building…"
if ! $BUILD build > $BUILD_LOG 2>&1; then
  grep -E 'error:' $BUILD_LOG || tail -20 $BUILD_LOG
  echo "Build failed. Full log: $BUILD_LOG"
  exit 1
fi
grep -E '(warning|error):' $BUILD_LOG | grep -v appintentsmetadataprocessor || echo "Build succeeded, 0 warnings"

APP=$($BUILD -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" { print $3 }')/SignDrop.app
BINARY=$APP/Contents/MacOS/SignDrop

if pgrep -f $BINARY > /dev/null; then
  echo "Quitting the running SignDrop…"
  pkill -TERM -f $BINARY
  for i in {1..20}; do
    pgrep -f $BINARY > /dev/null || break
    sleep 0.25
  done
fi

MARKER=$(mktemp -t signdrop-launch)
for i in {1..5}; do
  open $APP 2>/dev/null && break
  sleep 1
done

for i in {1..40}; do
  LOG=$(find $TMPDIR -maxdepth 1 -name 'com.mahmuthanelbir.signdrop-*.log' -newer $MARKER 2>/dev/null | head -1)
  [[ -n $LOG ]] && grep -q 'Ready$' $LOG && break
  sleep 0.25
done
rm -f $MARKER

if [[ -n $LOG ]] && grep -q 'Ready$' $LOG; then
  echo "SignDrop is running: $APP"
  echo "Log: $LOG"
else
  echo "SignDrop did not report Ready. Log: ${LOG:-not found}"
  exit 1
fi
