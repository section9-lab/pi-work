#!/bin/bash
# Release-mode A/B/B/A of the REAL ChatView in an isolated SwiftPM package.
# Requires macOS + Xcode and a WindowServer session. Does not alter production files.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${PI_WORK_MARKDOWN_PERF_ROOT:-$SOURCE/build/MarkdownWindowBenchmark}"
mkdir -p "$ROOT"
python3 - "$SOURCE" "$ROOT" <<'PY'
import json, os, pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
folders = [] if os.environ.get('PERF_REUSE_STAGE') == '1' else [('PiWork', 'Sources/PiWork'), ('PiWorkTests', 'Tests/PiWorkTests')]
for folder, dest in folders:
    shutil.rmtree(target / dest, ignore_errors=True)
    for path in (source / folder).rglob('*.swift'):
        out = target / dest / path.relative_to(source / folder)
        out.parent.mkdir(parents=True, exist_ok=True)
        text = path.read_text()
        if path.name in ['ContentView.swift', 'UserAccountPopover.swift'] and '\n#Preview' in text:
            text = text.split('\n#Preview', 1)[0] + '\n'
        out.write_text(text.replace('#filePath', json.dumps(str(path))))
test = target / 'Tests/PiWorkTests/SessionStoreTests.swift'
original = test.read_text().split('// Appended to SessionStoreTests.swift ONLY', 1)[0].rstrip()
benchmark = (source / 'scripts/MarkdownWindowPerformance.swift').read_text()
updated = original + '\n\n' + benchmark
if updated != test.read_text(): test.write_text(updated)
(target / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PiWorkMarkdownPerformance", platforms: [.macOS(.v13)], dependencies: [
 .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
 .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
 .package(url: "https://github.com/mixpanel/mixpanel-swift", revision: "3ad0fb82216978c124b04accac6c9f9eaf848187")
], targets: [
 .executableTarget(name: "PiWork", dependencies: [.product(name: "Sparkle", package: "Sparkle"), .product(name: "MarkdownUI", package: "swift-markdown-ui"), .product(name: "Mixpanel", package: "mixpanel-swift")]),
 .testTarget(name: "PiWorkTests", dependencies: ["PiWork"])
])
''')
PY
# Reuse pinned dependency clones when available; no source edits in that cache.
if [ -d "$SOURCE/build/CompactionNative/.build/checkouts" ] && [ ! -d "$ROOT/.build/checkouts" ]; then
  mkdir -p "$ROOT/.build"
  cp -R "$SOURCE/build/CompactionNative/.build/checkouts" "$ROOT/.build/"
  cp -R "$SOURCE/build/CompactionNative/.build/repositories" "$ROOT/.build/"
  cp "$SOURCE/build/CompactionNative/.build/workspace-state.json" "$ROOT/.build/"
  cp "$SOURCE/build/CompactionNative/Package.resolved" "$ROOT/"
fi
{
  date -u '+date_utc=%Y-%m-%dT%H:%M:%SZ'
  git -C "$SOURCE" rev-parse HEAD
  sw_vers
  sysctl -n machdep.cpu.brand_string hw.memsize
  swift --version
  shasum -a 256 "$ROOT/Sources/PiWork/Features/Chat/Views/ChatView.swift" \
    "$ROOT/Sources/PiWork/Features/Chat/Views/AssistantMarkdownView.swift" \
    "$ROOT/Sources/PiWork/Core/Agent/SessionStore.swift" "$SOURCE/scripts/MarkdownWindowPerformance.swift"
} > "$ROOT/environment.txt"
for RUN in ${PERF_RUNS:-40a 100a 100b 40b}; do
  BATCH="${RUN%[ab]}"
  python3 - "$ROOT/Sources/PiWork/Features/Chat/ChatPresentation.swift" "$BATCH" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text, count = re.subn(r'(struct TranscriptWindow: Equatable \{\n    static let batchSize = )\d+',
                     lambda m: m[1] + sys.argv[2], path.read_text())
assert count == 1
if text != path.read_text(): path.write_text(text)
PY
  swift build --package-path "$ROOT" -c release --build-tests -Xswiftc -enable-testing -j 4 > "$ROOT/build-$RUN.log" 2>&1
  BUNDLE="$(find "$ROOT/.build" -type d -ipath '*release/*.xctest' -print -quit)"
  [ -n "$BUNDLE" ] || { echo "Release XCTest bundle not found" >&2; exit 1; }
  mkdir -p "$BUNDLE/Contents/Resources"
  cp -R "$SOURCE"/PiWork/Resources/*.lproj "$BUNDLE/Contents/Resources/"
  cp "$SOURCE"/PiWork/Resources/Lucide*.pdf "$BUNDLE/Contents/Resources/"
  # Do not benchmark while this or another session is compiling Swift.
  while pgrep -x swift-frontend >/dev/null; do sleep 2; done
  NSUnbufferedIO=YES PERF_RUN="$RUN" PERF_ITERATIONS="${PERF_ITERATIONS:-2}" \
    xcrun xctest -XCTest PiWorkTests.SessionStoreTests/testMarkdownWindowPerformance "$BUNDLE" \
    2>&1 | tee "$ROOT/run-$RUN.log"
done
python3 "$SOURCE/scripts/summarize-markdown-benchmark.py" "$ROOT" > "$ROOT/summary.md"
printf '\nResults: %s/summary.md\n' "$ROOT"
