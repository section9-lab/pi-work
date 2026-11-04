#!/bin/bash
# Repeatable live-stream diagnosis over a frozen Release test bundle.
# Runs the scenario matrix from scripts/transcript-diagnosis-scenarios.json,
# captures process-load context and optional `sample` profiles, then summarizes.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$SOURCE/build/TranscriptAcceptance"
BASELINE="${PERF_BASELINE:-$ROOT/baseline-source}"
STAGE_ROOT="$ROOT/diagnosis"
SCENARIOS="${SCENARIOS_JSON:-$SOURCE/scripts/transcript-diagnosis-scenarios.json}"
LABEL="${DIAG_LABEL:-diagnosis-$(date +%Y%m%d-%H%M%S)}"
OUT="$ROOT/$LABEL"
mkdir -p "$OUT"

[ -f "$BASELINE/PiWork/Core/Agent/SessionStore.swift" ] || {
    echo "Baseline source snapshot missing: $BASELINE" >&2; exit 1; }
[ -f "$SCENARIOS" ] || { echo "Scenario registry missing: $SCENARIOS" >&2; exit 1; }

ALL_NAMES="$(python3 "$SOURCE/scripts/summarize-transcript-diagnosis.py" --list-names --scenarios-json "$SCENARIOS")"
if [ $# -gt 0 ]; then
    SCENARIO_NAMES="$*"
    for name in $SCENARIO_NAMES; do
        case " $ALL_NAMES " in
            *" $name "*) ;;
            *) echo "Unknown scenario: $name (known: $ALL_NAMES)" >&2; exit 1 ;;
        esac
    done
else
    SCENARIO_NAMES="$ALL_NAMES"
fi

if [ "${PERF_DIAG_REUSE_BUILD:-0}" != 1 ]; then
    python3 "$SOURCE/scripts/stage-transcript-acceptance.py" "$SOURCE" "$BASELINE" "$STAGE_ROOT" after
    swift build --package-path "$STAGE_ROOT/after" -c release --build-tests \
        -Xswiftc -enable-testing -j "${PERF_BUILD_JOBS:-2}" > "$OUT/build.log" 2>&1
fi
BUNDLE=""
for candidate in \
    "$STAGE_ROOT/after/.build/out/Products/Release/PiWorkTests.xctest" \
    "$STAGE_ROOT/after/.build/release/PiWorkTests.xctest"; do
    [ -x "$candidate/Contents/MacOS/PiWorkTests" ] && BUNDLE="$candidate" && break
done
if [ -z "$BUNDLE" ]; then
    BUNDLE="$(find "$STAGE_ROOT/after/.build" -type d -ipath '*release/*.xctest' -print 2>/dev/null | while IFS= read -r candidate; do
        [ -x "$candidate/Contents/MacOS/PiWorkTests" ] && { printf '%s\n' "$candidate"; break; }
    done | head -1)"
fi
[ -n "$BUNDLE" ] || { echo "Release test bundle not found" >&2; exit 1; }
mkdir -p "$BUNDLE/Contents/Resources"
cp -R "$SOURCE/PiWork/Resources/"*.lproj "$BUNDLE/Contents/Resources/"
cp "$SOURCE"/PiWork/Resources/Lucide*.pdf "$BUNDLE/Contents/Resources/"
printf '%s\n' "$BUNDLE" > "$OUT/bundle.txt"

{
    date -u '+date_utc=%Y-%m-%dT%H:%M:%SZ'
    git -C "$SOURCE" rev-parse HEAD
    sw_vers
    sysctl -n machdep.cpu.brand_string hw.memsize
    uptime
    sysctl vm.swapusage
    swift --version
} > "$OUT/environment.txt"

run_one() {
    local name="$1" scenario_env="$2"
    while pgrep -x swift-frontend >/dev/null; do sleep 2; done
    sleep "${PERF_COOLDOWN_SECONDS:-2}"
    # Export scenario variables into the test process environment instead of
    # re-parsing a command line; all values are simple strings.
    python3 -c '
import json, sys
for key, value in sorted(json.load(open(sys.argv[1])).items()):
    print(f"{key}={value}")
' "$scenario_env" > "$scenario_env.lines"
    {
        date -u '+time_utc=%Y-%m-%dT%H:%M:%SZ'
        uptime
        sysctl vm.swapusage
        ps -axo pid,%cpu,rss,comm | sort -k2 -nr | head -10
    } > "$OUT/load-$name.txt" || true
    echo "Scenario $name started at $(date)"
    export NSUnbufferedIO=YES PERF_VARIANT=after
    export PERF_RUN="$name"
    export PERF_COMPLEX_FIXTURE="$SOURCE/PiWorkTests/Fixtures/markdown/performance-complex.md"
    export PERF_DIAG_TIMEOUT_MS="${PERF_DIAG_TIMEOUT_MS:-120000}"
    export PERF_DIAG_SAMPLE_MS="${PERF_DIAG_SAMPLE_MS:-500}"
    while IFS= read -r scenario_entry; do
        [ -n "$scenario_entry" ] && export "$scenario_entry"
    done < "$scenario_env.lines"
    xcrun xctest -XCTest PiWorkTests.SessionStoreTests/testTranscriptAcceptanceLiveDiagnosis \
        "$BUNDLE" > "$OUT/$name.log" 2>&1 &
    local pid=$!
    if [ "${PERF_DIAG_PROFILE:-1}" = 1 ]; then
        for _ in $(seq 1 600); do
            rg -q 'LIVE_DIAG_START' "$OUT/$name.log" 2>/dev/null && break
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            sample "$pid" "${PERF_DIAG_PROFILE_SECONDS:-10}" \
                -file "$OUT/profile-$name.txt" >/dev/null 2>&1 || true
        fi
    fi
    wait "$pid" || true
}

for name in $SCENARIO_NAMES; do
    ENV_JSON="$OUT/.scenario-env-$name.json"
    python3 -c '
import json, pathlib, sys
scenarios = json.load(open(sys.argv[1]))
name = sys.argv[2]
match = [s for s in scenarios if s["name"] == name]
assert match, "scenario missing: " + name
pathlib.Path(sys.argv[3]).write_text(json.dumps(match[0]["env"]))
' "$SCENARIOS" "$name" "$ENV_JSON"
    run_one "$name" "$ENV_JSON"
    rm -f "$ENV_JSON"
done

python3 "$SOURCE/scripts/summarize-transcript-diagnosis.py" \
    --scenarios-json "$SCENARIOS" --run-dir "$OUT" --names $SCENARIO_NAMES
