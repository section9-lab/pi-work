#!/bin/bash
# Streaming Markdown render benchmark.
#
# Stages the shipped parser/segmenter plus the bench harness into a throwaway
# SwiftPM package (the same trick as scripts/test-native.sh), builds it in
# Release, and prints per-tick render cost for:
#
#   A  whole document   (current shipped path)
#   B  block memo       (memoized per block, eager VStack)
#   C  block memo lazy  (memoized per block, LazyVStack)
#
# Usage: scripts/benchmark-markdown-streaming.sh [fixture.md]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${1:-$ROOT/PiWorkTests/Fixtures/markdown/performance-complex.md}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/Sources/Bench"
cp "$ROOT/PiWork/Features/Chat/StreamingMarkdownAccumulator.swift" "$STAGE/Sources/Bench/"
cp "$ROOT/bench/markdown-streaming/main.swift" "$STAGE/Sources/Bench/"

cat > "$STAGE/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "MarkdownStreamingBench",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1")
  ],
  targets: [
    .executableTarget(
      name: "Bench",
      dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")]
    )
  ]
)
PACKAGE

echo "Building benchmark (Release)…"
swift build --package-path "$STAGE" -c release ${PI_WORK_NATIVE_SKIP_UPDATE:+--skip-update}
BIN="$(swift build --package-path "$STAGE" -c release --show-bin-path)"
"$BIN/Bench" "$FIXTURE"
