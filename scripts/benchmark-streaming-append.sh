#!/bin/bash
# Opt-in scaling check for the streaming token path. Builds the same staged
# SwiftPM package as test-native.sh, then runs only the gated benchmark test.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${PI_WORK_NATIVE_CHECK_ROOT:-$SOURCE/build/NativeChecks/streaming-append}"
mkdir -p "$ROOT"
{
  date -u '+date_utc=%Y-%m-%dT%H:%M:%SZ'
  git -C "$SOURCE" rev-parse --short HEAD
  sw_vers
  sysctl -n machdep.cpu.brand_string hw.memsize
  swift --version
} | tee "$ROOT/environment.txt"
PERF_STREAMING_APPEND=1 \
  PI_WORK_NATIVE_SKIP_UPDATE=1 \
  PI_WORK_NATIVE_CHECK_ROOT="$ROOT" \
  NATIVE_TEST_FILTER="SessionStoreReducerTests/testStreamingAppendScalesNearLinearlyWithFixedFlushes" \
  "$SOURCE/scripts/test-native.sh" 2>&1 | tee "$ROOT/run.log"
