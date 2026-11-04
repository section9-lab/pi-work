# Transcript live-stream diagnosis harness

A repeatable way to localize the known live-stream lag (complex Markdown layout blocking the main actor) without touching production behavior. It complements the acceptance run in [`transcript-acceptance-2026-11-04.md`](transcript-acceptance-2026-11-04.md) and is **not** a performance-ratio measurement.

## What it answers

Three counters make the streaming pipeline observable in one process:

| Counter | Meaning | Lag signature |
|---|---|---|
| `emitted` | events the fake producer sent into the fake host stream | grows if the store cannot consume |
| `received` / `received_seq` | events pulled off the stream and handed to the reducer on the main actor | queue backlog = emitted − received |
| `processed` / `processed_seq` | records updated by the reducer | reducer backlog — should track received closely |
| `published` / `published_seq` | records dispatched to UI subscriptions | publish delay uses the streaming coalesce window, so `published_seq` may trail `processed_seq` by design |

Scenario variants isolate causes: `unmounted` (Store only), `mounted` (normal layout), `forced` (benchmark-style forced layout + scrolling), near-empty history (`PERF_DIAG_ROWS=3`) vs 1,000 sources, complex vs plain live body, complex vs plain history sources.

The instrumentation lives in `PiWork/Core/Agent/SessionStore.swift` (`SessionStoreDiagnostics`, compiled only under `DEBUG || TRANSCRIPT_ACCEPTANCE`); the scenario test is `testTranscriptAcceptanceLiveDiagnosis` in `scripts/MarkdownIsolationPerformance.swift`, staged into the frozen Release bundle by `scripts/stage-transcript-acceptance.py`.

## Usage

```bash
# Full matrix (stages + builds once; reuses build with PERF_DIAG_REUSE_BUILD=1)
scripts/benchmark-transcript-diagnosis.sh

# Selected scenarios into a named directory
PERF_DIAG_REUSE_BUILD=1 DIAG_LABEL=diag-2026-11-04-fix-a \
  scripts/benchmark-transcript-diagnosis.sh unmounted-mixed-1000 mounted-mixed-1000
```

Outputs land in `build/TranscriptAcceptance/<label>/`: per-scenario logs (`<scenario>.log`), load snapshots (`load-<scenario>.txt`) capturing uptime/swap/top processes, optional `sample` profiles taken during streaming (`profile-<scenario>.txt`, `PERF_DIAG_PROFILE=0` to skip), plus `summary.md`, `results.json` and `environment.txt`.

The summarizer (`scripts/summarize-transcript-diagnosis.py`) fails (exit 1) when any requested scenario lacks a valid result, an expected completion, or the mounted-render check; `--relaxed` downgrades that to a warning. A scenario is valid only when the published sequence equals the expected sequence **and** the mounted-presentation check matched — send-at producer completion by itself is never a pass.

### Scenario registry

`scripts/transcript-diagnosis-scenarios.json` defines the matrix; add rows with `name`, `description`, `env` and the expectations `expect_complete` / `expect_render`. Common overrides: `PERF_DIAG_TIMEOUT_MS` (default 120 s per scenario), `PERF_DIAG_SAMPLE_MS` (default 500), `PERF_COOLDOWN_SECONDS`, `PERF_BUILD_JOBS`, `PERF_DIAG_PROFILE`, `PERF_DIAG_PROFILE_SECONDS`, `PERF_DIAG_REUSE_BUILD` (skips staging+build; only use when the staged production code is unchanged).

## Interpreting results

- `unmounted` should complete with near-zero lag; it validates the producer/store path and machine health. A slow unmounted run usually means a contaminated machine — rerun.
- `publish_lag_ms` (store completion minus input completion) is the headline symptom. Compare `mounted` minus `unmounted` and `forced` minus `mounted`; the deltas isolate what mounting the UI and forcing layout cost.
- During a failure, `LIVE_DIAG_STAGES` decides where data waits: `receive_backlag > 0` means main-actor starvation upstream of the reducer (consistent with the layout-blocking hypothesis); `received ≈ processed` but low `published_seq` alone would instead point downstream. `LIVE_DIAG_SAMPLE` lines give this progression over time.
- `sample` profiles answer *which* layout work blocks the thread (e.g. `GraphHost.flushTransactions` under `NSHostingView.beginTransaction`).

## Known limits

- Single-run observations are noisy on a loaded machine; record `load-*.txt` context and rerunmedian conclusions rather than comparing single numbers.
- The producer emits into an in-process fake host; real IPC and disk are not covered.
- `SessionStoreDiagnostics` compiles into Debug and `TRANSCRIPT_ACCEPTANCE` builds only; the counting is cheap but nonzero — do not use Debug runs for baselines that should exclude it.
- This harness never substitutes for the acceptance suite (correctness gates, history navigation, coverage).
- Ambient load moves absolute numbers a lot; when A/B-comparing a change, re-measure the baseline in the same session on the same idle machine (see the negative container-isolation result in `stream-bottleneck-2026-11-04.md`).

Sample profiles are summarized by `scripts/summarize-diagnosis-profiles.py` (top-of-stack leaves by module plus approximate ancestor shares). See [`stream-bottleneck-2026-11-04.md`](stream-bottleneck-2026-11-04.md) for the first round of analysis.
