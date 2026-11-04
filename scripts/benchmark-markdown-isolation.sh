#!/bin/bash
# Same Release binary, same complex fixture, baseline 100 vs fixed-100 + isolated text.
# Experimental implementation is staged under build/, never patched into PiWork/.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$SOURCE/build/MarkdownIsolationBenchmark"
mkdir -p "$ROOT"
if [ "${PERF_REUSE_STAGE:-0}" != 1 ]; then
  python3 "$SOURCE/scripts/stage-markdown-isolation.py" "$SOURCE" "$ROOT"
fi
CACHE="$SOURCE/build/MarkdownWindowBenchmark"
if [ ! -d "$ROOT/.build/checkouts" ] && [ -d "$CACHE/.build/checkouts" ]; then
  mkdir -p "$ROOT/.build"
  for PART in checkouts repositories workspace-state.json; do cp -R "$CACHE/.build/$PART" "$ROOT/.build/"; done
  cp "$CACHE/Package.resolved" "$ROOT/"
fi
{
  date -u '+date_utc=%Y-%m-%dT%H:%M:%SZ'
  git -C "$SOURCE" rev-parse HEAD
  sw_vers
  sysctl -n machdep.cpu.brand_string hw.memsize
  swift --version
  shasum -a 256 "$ROOT/complex.md" "$SOURCE/scripts/MarkdownIsolationCandidate.swift" \
    "$SOURCE/scripts/MarkdownIsolationPerformance.swift" "$SOURCE/scripts/stage-markdown-isolation.py"
} > "$ROOT/environment.txt"
swift build --package-path "$ROOT" -c release --build-tests -Xswiftc -enable-testing -j 4 > "$ROOT/build.log" 2>&1
BUNDLE="$(find "$ROOT/.build" -type d -ipath '*release/*.xctest' -print -quit)"
[ -n "$BUNDLE" ] || { echo 'Release XCTest bundle not found' >&2; exit 1; }
mkdir -p "$BUNDLE/Contents/Resources"
cp -R "$SOURCE"/PiWork/Resources/*.lproj "$BUNDLE/Contents/Resources/"
cp "$SOURCE"/PiWork/Resources/Lucide*.pdf "$BUNDLE/Contents/Resources/"
# Verify structural invalidation, completion, sequence handling and navigation
# before collecting timings. Run both runtime branches of the same binary.
for VARIANT in baseline combined; do
  NSUnbufferedIO=YES PERF_VARIANT="$VARIANT" PERF_COMPLEX_FIXTURE="$ROOT/complex.md" xcrun xctest -XCTest \
    PiWorkTests.SessionStoreTests/testMarkdownIsolationEventBoundaries,PiWorkTests.SessionStoreTests/testMarkdownIsolationNavigationBoundaries,PiWorkTests.AssistantMarkdownPresentationTests,PiWorkTests.AssistantTimelinePresentationTests,PiWorkTests.SessionStoreReducerTests \
    "$BUNDLE" > "$ROOT/correctness-$VARIANT.log" 2>&1
  if NSUnbufferedIO=YES PERF_VARIANT="$VARIANT" PERF_COMPLEX_FIXTURE="$ROOT/complex.md" \
    xcrun xctest -XCTest PiWorkTests.SessionStoreTests/testMarkdownIsolationVisibleRenderer \
    "$BUNDLE" > "$ROOT/renderer-check-$VARIANT.log" 2>&1; then
    echo "$VARIANT final-render check: passed"
  elif [ "$VARIANT" = baseline ] && \
       [ "$(grep -c 'error:' "$ROOT/renderer-check-$VARIANT.log")" = 1 ] && \
       grep -q 'Mounted Markdown presentation must contain the final text' "$ROOT/renderer-check-$VARIANT.log"; then
    echo 'BASELINE CORRECTNESS FAILURE: final text is stale; live-stream timings will be marked invalid, not treated as a performance win.'
  else
    echo "Unexpected renderer failure: $ROOT/renderer-check-$VARIANT.log" >&2
    exit 1
  fi
done
for RUN in ${PERF_RUNS:-baseline-dense combined-dense baseline-a combined-a combined-b baseline-b}; do
  VARIANT="${RUN%%-*}"
  DENSITY=mixed; SCOPE=all
  if [[ "$RUN" == *-dense ]]; then DENSITY=dense; SCOPE=cold-only; fi
  while pgrep -x swift-frontend >/dev/null; do sleep 2; done
  sleep "${PERF_COOLDOWN_SECONDS:-3}"
  ps -axo pid,%cpu,rss,command | sort -k2 -nr | head -15 > "$ROOT/load-$RUN.txt" || true
  NSUnbufferedIO=YES PERF_VARIANT="$VARIANT" PERF_RUN="$RUN" \
    PERF_ITERATIONS="${PERF_ITERATIONS:-1}" PERF_DENSITY="$DENSITY" PERF_SCOPE="$SCOPE" \
    PERF_COMPLEX_FIXTURE="$ROOT/complex.md" \
    xcrun xctest -XCTest PiWorkTests.SessionStoreTests/testMarkdownIsolationBenchmark "$BUNDLE" \
    2>&1 | tee "$ROOT/run-$RUN.log"
done
if [ "${PERF_SUMMARIZE:-1}" != 0 ]; then
  python3 "$SOURCE/scripts/summarize-markdown-isolation.py" "$ROOT" > "$ROOT/summary.md"
fi
printf '\nResults: %s/summary.md\n' "$ROOT"
