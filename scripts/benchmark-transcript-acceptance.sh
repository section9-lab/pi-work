#!/bin/bash
# Actual production before/after, separate frozen Release binaries, A/B/B/A.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$SOURCE/build/TranscriptAcceptance/performance"
BASELINE="${1:-$SOURCE/build/TranscriptAcceptance/baseline-source}"
mkdir -p "$ROOT"
cp -p "$SOURCE/scripts/transcript-acceptance-gates.json" "$ROOT/acceptance-gates.json"
if [ "${PERF_REUSE_STAGE:-0}" != 1 ]; then
  python3 "$SOURCE/scripts/stage-transcript-acceptance.py" "$SOURCE" "$BASELINE" "$ROOT"
fi
{
  date -u '+date_utc=%Y-%m-%dT%H:%M:%SZ'
  git -C "$SOURCE" rev-parse HEAD
  sw_vers
  sysctl -n machdep.cpu.brand_string hw.memsize
  swift --version
} > "$ROOT/environment.txt"
for VARIANT in before reference after; do
  TARGET="$ROOT/$VARIANT"
  swift build --package-path "$TARGET" -c release --build-tests -Xswiftc -enable-testing -j 4 > "$ROOT/build-$VARIANT.log" 2>&1
  BUNDLE="$(find "$TARGET/.build" -type d -ipath '*release/*.xctest' -print -quit)"
  [ -n "$BUNDLE" ] || exit 1
  mkdir -p "$BUNDLE/Contents/Resources"
  cp -R "$SOURCE"/PiWork/Resources/*.lproj "$BUNDLE/Contents/Resources/"
  cp "$SOURCE"/PiWork/Resources/Lucide*.pdf "$BUNDLE/Contents/Resources/"
  printf '%s\n' "$BUNDLE" > "$ROOT/bundle-$VARIANT.txt"
done
[ "${PERF_BUILD_ONLY:-0}" != 1 ] || exit 0
for VARIANT in reference after; do
  BUNDLE="$(<"$ROOT/bundle-$VARIANT.txt")"
  NSUnbufferedIO=YES PERF_VARIANT="$VARIANT" PERF_COMPLEX_FIXTURE="$ROOT/$VARIANT/complex.md" \
    xcrun xctest -XCTest PiWorkTests.SessionStoreTests/testTranscriptAcceptanceVisibleRenderer "$BUNDLE" \
    > "$ROOT/renderer-check-$VARIANT.log" 2>&1
done
for RUN in ${PERF_RUNS:-reference-a after-a after-b reference-b reference-dense-a after-dense-a after-dense-b reference-dense-b}; do
  VARIANT="${RUN%%-*}"; DENSITY=mixed; SCOPE=all
  if [[ "$RUN" == *-dense-* ]]; then DENSITY=dense; SCOPE=cold-only; fi
  while pgrep -x swift-frontend >/dev/null; do sleep 2; done
  sleep "${PERF_COOLDOWN_SECONDS:-3}"
  ps -axo pid,%cpu,rss,command | sort -k2 -nr | head -15 > "$ROOT/load-$RUN.txt" || true
  BUNDLE="$(<"$ROOT/bundle-$VARIANT.txt")"
  NSUnbufferedIO=YES PERF_VARIANT="$VARIANT" PERF_RUN="$RUN" PERF_ITERATIONS=1 \
    PERF_DENSITY="$DENSITY" PERF_SCOPE="$SCOPE" PERF_COMPLEX_FIXTURE="$ROOT/$VARIANT/complex.md" \
    xcrun xctest -XCTest PiWorkTests.SessionStoreTests/testTranscriptAcceptanceBenchmark "$BUNDLE" \
    > "$ROOT/run-$RUN.log" 2>&1
  echo "Completed $RUN"
done
if [ "${PERF_SUMMARIZE:-1}" != 0 ]; then
  python3 "$SOURCE/scripts/summarize-transcript-acceptance.py" "$ROOT"
fi
