#!/bin/bash
# Stage the pinned, source-available helper under PiWork's own TCC identity.
set -euo pipefail
COMPUTER_USE_SOURCE="$1"
COMPUTER_USE_DESTINATION="$2"
COMPUTER_USE_IDENTITY="${3:--}"
COMPUTER_USE_BUNDLE_ID="${4:-cc.vibevibe.pi-work.computer-use}"
mkdir -p "$COMPUTER_USE_DESTINATION"
/usr/bin/ditto "$COMPUTER_USE_SOURCE/prebuilt/macos/universal/pi-computer-use.app" "$COMPUTER_USE_DESTINATION/pi-computer-use.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $COMPUTER_USE_BUNDLE_ID" "$COMPUTER_USE_DESTINATION/pi-computer-use.app/Contents/Info.plist"
if [ "$COMPUTER_USE_IDENTITY" = "-" ]; then
  /usr/bin/codesign --force --options runtime --sign - "$COMPUTER_USE_DESTINATION/pi-computer-use.app"
else
  /usr/bin/codesign --force --preserve-metadata=entitlements --options runtime --timestamp --sign "$COMPUTER_USE_IDENTITY" "$COMPUTER_USE_DESTINATION/pi-computer-use.app"
fi
/usr/bin/codesign --verify --strict "$COMPUTER_USE_DESTINATION/pi-computer-use.app"
cp "$COMPUTER_USE_SOURCE/LICENSE" "$COMPUTER_USE_DESTINATION/LICENSE"
