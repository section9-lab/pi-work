#!/bin/bash
# Build an isolated, credential-free native QA application with Command Line Tools.
set -euo pipefail
COMPUTER_USE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$COMPUTER_USE_ROOT"
COMPUTER_USE_ARCH="arm64"
if [ "$(uname -m)" = "x86_64" ]; then COMPUTER_USE_ARCH="x64"; fi
COMPUTER_USE_BUN="$COMPUTER_USE_ROOT/build/Bun/$COMPUTER_USE_ARCH/bun"
(cd AgentHost && "$COMPUTER_USE_BUN" build --compile --no-compile-autoload-bunfig --target="bun-darwin-$COMPUTER_USE_ARCH" src/main.ts --outfile "../build/pi-work-computer-use-host-$COMPUTER_USE_ARCH")
/usr/bin/codesign --force --sign - "$COMPUTER_USE_ROOT/build/pi-work-computer-use-host-$COMPUTER_USE_ARCH"
COMPUTER_USE_APP="$COMPUTER_USE_ROOT/build/PiWork-ComputerUse.app"
COMPUTER_USE_HOST_RESOURCES="$COMPUTER_USE_APP/Contents/Resources/AgentHost/$COMPUTER_USE_ARCH"
mkdir -p "$COMPUTER_USE_APP/Contents/MacOS" "$COMPUTER_USE_HOST_RESOURCES"
cp "$COMPUTER_USE_ROOT/build/pi-work-computer-use-host-$COMPUTER_USE_ARCH" "$COMPUTER_USE_HOST_RESOURCES/pi-work-agent-host"
cp -R AgentHost/node_modules/@earendil-works/pi-coding-agent/dist/core/export-html "$COMPUTER_USE_HOST_RESOURCES/"
cp -R AgentHost/node_modules/@earendil-works/pi-coding-agent/dist/modes/interactive/theme "$COMPUTER_USE_HOST_RESOURCES/"
swiftc -target "$(uname -m)-apple-macosx13.0" -swift-version 5 -parse-as-library \
  PiWork/Core/UI/AppLanguage.swift PiWork/Core/UI/AppSettingsNavigation.swift PiWork/Core/Update/*.swift \
  PiWork/Core/Agent/AgentHostExecutable.swift PiWork/Core/Agent/AgentHostProtocol.swift \
  PiWork/Core/Agent/AgentHostLineFramer.swift PiWork/Core/Agent/AgentHostClient.swift \
  PiWork/Core/Agent/AgentHostService.swift PiWork/Core/Agent/MCPService.swift PiWork/Core/Agent/ComputerUseService.swift \
  PiWork/Core/Agent/SessionStore.swift PiWork/Core/Agent/SessionOpenPerformanceTracer.swift \
  PiWork/Features/Chat/ChatPresentation.swift \
  PiWork/Features/MCP/*.swift PiWork/Features/MCP/Views/*.swift \
  PiWork/Features/ComputerUse/*.swift PiWork/Features/ComputerUse/Views/*.swift \
  scripts/ComputerUsePreview.swift -o "$COMPUTER_USE_APP/Contents/MacOS/ComputerUsePreview"
cp -R PiWork/Resources/*.lproj "$COMPUTER_USE_APP/Contents/Resources/"
cp PiWork/Resources/Lucide*.pdf "$COMPUTER_USE_APP/Contents/Resources/"
bash scripts/stage-computer-use-helper.sh AgentHost/node_modules/@injaneity/pi-computer-use "$COMPUTER_USE_APP/Contents/Resources/ComputerUse"
cat > "$COMPUTER_USE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ComputerUsePreview</string>
<key>CFBundleIdentifier</key><string>cc.vibevibe.pi-work.computer-use-preview</string>
<key>CFBundleName</key><string>PiWork Computer Use</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$COMPUTER_USE_APP"
# Launch outside protected Documents folders, just as an installed application.
COMPUTER_USE_INSTALLED_APP="$HOME/Library/Caches/pi-work/ComputerUseQA/PiWork-ComputerUse.app"
mkdir -p "$(dirname "$COMPUTER_USE_INSTALLED_APP")"
/usr/bin/ditto "$COMPUTER_USE_APP" "$COMPUTER_USE_INSTALLED_APP"
printf 'Built %s\n' "$COMPUTER_USE_APP"
printf 'Launch: open %q\n' "$COMPUTER_USE_INSTALLED_APP"
