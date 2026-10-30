#!/bin/bash
set -euo pipefail
APP_UPDATE_CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_UPDATE_CHECK_ROOT"
bash scripts/fetch-sparkle-tools.sh >/dev/null
APP_UPDATE_CHECK_APP="$APP_UPDATE_CHECK_ROOT/build/AppUpdateChecks.app"
mkdir -p "$APP_UPDATE_CHECK_APP/Contents/MacOS" "$APP_UPDATE_CHECK_APP/Contents/Resources" "$APP_UPDATE_CHECK_APP/Contents/Frameworks"
swiftc -target "$(uname -m)-apple-macosx13.0" -swift-version 5 -parse-as-library \
  -F build/Sparkle-2.10.1 -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  PiWork/Core/UI/AppLanguage.swift PiWork/Core/UI/AppPalette.swift PiWork/Core/UI/AppTheme.swift \
  PiWork/Core/UI/AdaptiveCornerShape.swift PiWork/Core/Update/ReleaseVersion.swift \
  PiWork/Features/Updates/*.swift scripts/AppUpdateChecks.swift -o "$APP_UPDATE_CHECK_APP/Contents/MacOS/AppUpdateChecks"
ditto build/Sparkle-2.10.1/Sparkle.framework "$APP_UPDATE_CHECK_APP/Contents/Frameworks/Sparkle.framework"
cp -R PiWork/Resources/*.lproj "$APP_UPDATE_CHECK_APP/Contents/Resources/"
cat > "$APP_UPDATE_CHECK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AppUpdateChecks</string>
<key>CFBundleIdentifier</key><string>cc.vibevibe.pi-work.app-update-checks</string>
<key>CFBundleName</key><string>App Update Checks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --deep --preserve-metadata=entitlements,flags,runtime --sign - "$APP_UPDATE_CHECK_APP"
"$APP_UPDATE_CHECK_APP/Contents/MacOS/AppUpdateChecks" "$APP_UPDATE_CHECK_ROOT/build"
