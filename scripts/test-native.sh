#!/bin/bash
# Compile the native app and run XCTest with Command Line Tools. The temporary
# SwiftPM project uses the same pinned MarkdownUI dependency as project.yml.
# Xcode-only development previews are omitted; production sources stay intact.
set -euo pipefail
NATIVE_SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${PI_WORK_NATIVE_CHECK_ROOT:-}" ]; then
  NATIVE_CHECK_ROOT="$PI_WORK_NATIVE_CHECK_ROOT"
  mkdir -p "$NATIVE_CHECK_ROOT"
else
  NATIVE_CHECK_ROOT="$(mktemp -d)"
  trap 'rm -rf "$NATIVE_CHECK_ROOT"' EXIT
fi
python3 - "$NATIVE_SOURCE_ROOT" "$NATIVE_CHECK_ROOT" <<'PY'
import json, pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
for folder, destination in [('PiWork', 'Sources/PiWork'), ('PiWorkTests', 'Tests/PiWorkTests')]:
    shutil.rmtree(target / destination, ignore_errors=True)
    for original in (source / folder).rglob('*.swift'):
        output = target / destination / original.relative_to(source / folder)
        output.parent.mkdir(parents=True, exist_ok=True)
        text = original.read_text()
        if original.name in ['ContentView.swift', 'UserAccountPopover.swift'] and '\n#Preview' in text:
            text = text.split('\n#Preview', 1)[0] + '\n'
        # Preserve test fixture/source discovery and diagnostics after staging.
        output.write_text(text.replace('#filePath', json.dumps(str(original))))
(target / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PiWorkNativeChecks", platforms: [.macOS(.v13)], dependencies: [
 .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
 .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
 .package(url: "https://github.com/mixpanel/mixpanel-swift", revision: "3ad0fb82216978c124b04accac6c9f9eaf848187")
], targets: [
 .executableTarget(name: "PiWork", dependencies: [.product(name: "Sparkle", package: "Sparkle"), .product(name: "MarkdownUI", package: "swift-markdown-ui"), .product(name: "Mixpanel", package: "mixpanel-swift")]),
 .testTarget(name: "PiWorkTests", dependencies: ["PiWork"])
])
''')
PY
swift build --package-path "$NATIVE_CHECK_ROOT" -j 4
if ! xcrun --find xctest >/dev/null 2>&1; then
  cd "$NATIVE_SOURCE_ROOT"
  swiftc -swift-version 5 -parse-as-library \
    PiWork/Core/UI/AppLanguage.swift PiWork/Core/UI/AppSettingsNavigation.swift PiWork/Core/Update/*.swift \
    PiWork/Core/Agent/AgentHostExecutable.swift PiWork/Core/Agent/AgentHostProtocol.swift \
    PiWork/Core/Agent/AgentHostLineFramer.swift PiWork/Core/Agent/AgentHostClient.swift \
    PiWork/Core/Agent/AgentHostService.swift PiWork/Core/Agent/MCPService.swift PiWork/Core/Agent/ComputerUseService.swift PiWork/Core/Agent/RTKService.swift \
    PiWork/Core/Agent/SessionStore.swift PiWork/Core/Agent/SessionOpenPerformanceTracer.swift \
    PiWork/Features/Chat/ChatPresentation.swift \
    PiWork/Features/MCP/*.swift PiWork/Features/MCP/Views/*.swift \
    PiWork/Features/ComputerUse/*.swift PiWork/Features/ComputerUse/Views/*.swift \
    PiWork/Features/RTK/*.swift PiWork/Features/RTK/Views/*.swift \
    scripts/ComputerUseChecks.swift scripts/RTKChecks.swift scripts/RunningInputChecks.swift scripts/MCPChecks.swift -o "$NATIVE_CHECK_ROOT/mcp-checks"
  # Bundle native resources so icon, localization and layout checks match the app.
  NATIVE_CHECK_APP="$NATIVE_CHECK_ROOT/MCPChecks.app"
  mkdir -p "$NATIVE_CHECK_APP/Contents/MacOS" "$NATIVE_CHECK_APP/Contents/Resources"
  cp "$NATIVE_CHECK_ROOT/mcp-checks" "$NATIVE_CHECK_APP/Contents/MacOS/MCPChecks"
  cp -R PiWork/Resources/*.lproj "$NATIVE_CHECK_APP/Contents/Resources/"
  cp PiWork/Resources/Lucide*.pdf "$NATIVE_CHECK_APP/Contents/Resources/"
  cat > "$NATIVE_CHECK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MCPChecks</string>
<key>CFBundleIdentifier</key><string>cc.vibevibe.pi-work.mcp-checks</string>
<key>CFBundleName</key><string>MCP Checks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  "$NATIVE_CHECK_APP/Contents/MacOS/MCPChecks" "$NATIVE_SOURCE_ROOT"
  echo "Native application compiled and MCP checks passed. Full XCTest requires Xcode."
  exit 0
fi
swift build --package-path "$NATIVE_CHECK_ROOT" --build-tests -j 4
# L10n uses Bundle.main in both Xcode-hosted and standalone test runs.
NATIVE_TEST_BUNDLE="$(find "$NATIVE_CHECK_ROOT/.build" -type d -name '*.xctest' -print -quit)"
mkdir -p "$NATIVE_TEST_BUNDLE/Contents/Resources"
cp -R "$NATIVE_SOURCE_ROOT"/PiWork/Resources/*.lproj "$NATIVE_TEST_BUNDLE/Contents/Resources/"
cp "$NATIVE_SOURCE_ROOT"/PiWork/Resources/Lucide*.pdf "$NATIVE_TEST_BUNDLE/Contents/Resources/"
swift test --package-path "$NATIVE_CHECK_ROOT" --skip-build
