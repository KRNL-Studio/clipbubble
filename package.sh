#!/bin/zsh
# Builds and signs ClipBubble.app at the path given (default ./ClipBubble.app).
# Local builds can use Apple Development to keep macOS permissions across rebuilds.
set -e
cd "$(dirname "$0")"
APP=${1:-ClipBubble.app}
IDENTITIES=$(security find-identity -v -p codesigning)
ID=$(sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' <<< "$IDENTITIES" | head -1)
SIGN_OPTIONS=()
if [[ -n $ID ]]; then
  SIGN_OPTIONS+=(--options runtime)
fi
if [[ -v CLIPBUBBLE_TIMESTAMP ]]; then
  if [[ -n $ID ]]; then
    SIGN_OPTIONS+=(--timestamp)
  elif [[ -z $CLIPBUBBLE_ALLOW_ADHOC ]]; then
    echo "No Developer ID Application identity in the keychain for release signing." >&2
    exit 1
  fi
elif [[ -z $ID ]]; then
  ID=$(sed -n 's/.*"\(Apple Development: .*\)"/\1/p' <<< "$IDENTITIES" | head -1)
fi
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Info.plist $APP/Contents/
cp Assets/AppIcon.icns $APP/Contents/Resources/
# The Linux app ships inside, so Settings can set up Linux hosts over SSH.
mkdir -p $APP/Contents/Resources/linux
cp -R Linux/clipbubble Linux/extension Linux/install.sh Linux/clipbubble.service $APP/Contents/Resources/linux/
find $APP/Contents/Resources/linux -name __pycache__ -prune -exec rm -rf {} +
sed -n 's/^VERSION = "\(.*\)"/\1/p' Linux/clipbubble/engine.py > $APP/Contents/Resources/linux/VERSION
BIN=$APP/Contents/MacOS/ClipBubble
if [[ -v CLIPBUBBLE_TIMESTAMP ]]; then
  # A release runs on Intel Macs too. Dev builds skip the second slice to stay quick.
  swiftc -O -swift-version 5 -target arm64-apple-macos14 Sources/*.swift -o $BIN.arm64
  swiftc -O -swift-version 5 -target x86_64-apple-macos14 Sources/*.swift -o $BIN.x86_64
  lipo -create $BIN.arm64 $BIN.x86_64 -output $BIN
  rm $BIN.arm64 $BIN.x86_64
else
  swiftc -O -swift-version 5 -target $(uname -m)-apple-macos14 Sources/*.swift -o $BIN
fi
if [[ -n $ID ]]; then
  codesign --force "${SIGN_OPTIONS[@]}" -s "$ID" "$APP"
  echo "Signed with $ID"
else
  codesign --force -s - $APP
  echo "Signed ad hoc (-). macOS may ask for ClipBubble's permissions again for this build."
fi
