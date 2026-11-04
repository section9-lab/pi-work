# Transcript implementation acceptance — 2026-11-04

## Status: not fully accepted

The production implementation is in the working tree. A full Release run failed three history/anchor tests before the latest change. One concrete race was identified: after a window changes, layout preference frames can still belong to the old window, but the restoration code used them immediately and stopped after roughly 166 ms. Restoration now waits for frames matching the new window and a stable offset, with cancellation on user input. The anchor test also waits for the actual offset rather than a fixed sleep. This addresses that race, but does not prove it was the sole cause of all three failures.

After the change, one complete Debug and two complete Release runs passed (788 tests each), as did 79 focused Release tests. Interactive scrolling under pressure remains to be verified. The change should not yet be treated as release-ready.

The prior implementation's performance script numeric gates passed on collected samples, but they do not cover the latest restoration change and are **not overall acceptance**. A fresh attempt on the latest code failed in the corrected reference's live-stream phase: after the 10-second completion deadline, Store sequence was 71/150. The latest attempt produced no valid performance comparison. Logs are under `build/TranscriptAcceptance/performance/run-reference-a.log`. A separate latest-implementation run also failed the same completion check, at sequence 136/150, after a 14.1-second completion lag; see `build/TranscriptAcceptance/performance/run-after-a.log`. Thus the issue is not confined to the reference. The machine was highly contended and had approximately 18 GB swap in use; load is a plausible contributor, not a proven sole cause. These are deadline failures; they do not establish whether all data would eventually arrive while the same reply remains visible. Earlier failed benchmark logs are retained under `build/TranscriptAcceptance/performance-prior-freshness/contended-round/`. A prior dense reference run timed out at 120 seconds; subsequent dense runs used a 600-second collection timeout without changing the regression gates.

## Follow-up localization

The failed `after-a` live sample consumed 16.92 s of process CPU over 17.51 s wall time, with a 1.51 s p95 and 2.33 s maximum sampling gap. This is consistent with substantial work inside the benchmark process, not simply a process sleeping while waiting for input; process CPU includes all its threads and does not identify the hot function or exclude swapping and contention. The producer finished in 3.40 s. The subsequent history-stream sample consumed 2.11 s CPU and completed its checks, but it uses a different visibility state and runs after navigation, so it is not a controlled isolated comparison. The fake host uses an `AsyncStream`; the producer returning means it emitted the events, not that the Store consumed or published them. The reported sequence is the published `records` sequence, not a direct measurement of the event queue or internal reducer. Thus the existing log cannot distinguish queued events from reduced-but-not-yet-published events or pinpoint Markdown/layout cost.

The benchmark also calls `layoutSubtreeIfNeeded()` and maintains tail visibility during live sampling. Its gap and CPU measurements therefore include explicit benchmark-driven layout and scrolling, not just normal event processing. A profile and controlled runs with and without a mounted live surface are needed before attributing the backlog to a particular stage. The existing history sample is suggestive, not such a controlled run.

An opt-in diagnostic has been added to `scripts/MarkdownIsolationPerformance.swift`: set `PERF_LIVE_OBSERVE_MS=60000` when running the benchmark to continue observing the same visible reply after a live deadline failure. `LIVE_OBSERVATION` reports the published sequence and first observed Store-idle and mounted-render completion times relative to the beginning of that extra observation (`-1` means not observed). The original deadline assertions remain failures; this observation is not an acceptance sample. Assertions and their logging occur before observation, so its timestamps are not precise completion latencies from producer finish. The probe has only been syntax-checked, not executed in a benchmark.

At follow-up the machine still had approximately 16.8 GB swap in use and a one-minute load average near 40. No new stress run was started and no processes were stopped. Re-stage before using the new diagnostic (do not use `PERF_REUSE_STAGE=1` with an old staged helper), on an otherwise idle machine. Retain the failed logs separately before re-running because the benchmark overwrites its output paths.

## Controlled live-stream diagnosis

A Release-only diagnostic (`testTranscriptAcceptanceLiveDiagnosis`) sends the same detached-producer stream to the same Store with and without a mounted `ChatView`. The mounted cases use the same 840 × 640 surface. `mounted` lets AppKit/SwiftUI schedule layout normally; `forced` additionally calls `layoutSubtreeIfNeeded` and keeps the tail visible every sampling iteration, as the acceptance workload does. Store/render times below are from producer start, not completion lag. All render checks are the existing weak mounted-presentation check; they do not prove pixels were displayed. Logs and two macOS `sample` profiles are in `build/TranscriptAcceptance/diagnosis/`.

| Case | Input finished | Published Store idle / rendered | Process CPU | Result |
|---|---:|---:|---:|---|
| 1,000 sources, unmounted | 3.13 s | 3.13 s / n/a | 0.32 s | 151/151 |
| Same, mounted, normal layout | 3.46 s | 12.23 s / 12.23 s | 11.79 s | 151/151 |
| Same, forced layout and scroll | 3.94 s | not observed in 60 s | 50.23 s | 136/151 at timeout |
| 3 sources, forced, complex live text | 3.64 s | 16.05 s / 16.05 s | 10.63 s | 151/151 |
| 1,000 short history messages, forced, complex live text | 3.73 s | 16.32 s / 16.32 s | 10.04 s | 151/151 |
| 1,000 mixed-complex history messages, forced, plain live text | 3.70 s | not observed in 60 s | 21.23 s | 29/152 at timeout |
| 3 sources, forced, plain live text | 3.30 s | 3.45 s / 3.45 s | 2.41 s | 152/152 |

The short-history control uses user messages rather than preserving the role mix, so it is not a clean single-variable history-content experiment. Different live bodies also produce slightly different chunk counts. The machine remained contended and swapping, and these single observations are not a performance comparison. However, a repeat with lower load still showed 3.15 s unmounted versus 10.44 s mounted for the same mixed-complex case; 3-source forced complex versus plain was 5.25 s versus 3.37 s. Another forced mixed-complex run completed in 7.67 s, demonstrating large run-to-run variation; it does not establish eventual completion of the separate 60-second failure.

**Localized mechanism:** `SessionStore.beginObserving()` creates its event consumer on the main actor, which is also responsible for the mounted SwiftUI transcript. The transcript uses an eager `VStack` for its 100-source window so every row can be measured for anchor restoration. Updates to a growing Markdown response change layout within that large hierarchy. In the normal-layout sample, 7,579 of 10,651 main-thread samples were under `NSHostingView.beginTransaction` → `GraphHost.flushTransactions`, including `GeometryReaderLayout.placeSubviews` and `ScrollViewLayoutComputer.Engine.sizeThatFits`; this sample is not a CPU percentage. In the forced sample, 5,580 of 8,068 main-thread samples were under the diagnostic's `layoutSubtreeIfNeeded`, subsequently in the same SwiftUI layout machinery. While the main actor is occupied there, it cannot promptly consume and publish events. This explains the observed published-sequence lag without needing packet loss or swap as the sole explanation. The traces and controls do not prove precisely which SwiftUI invalidation or Markdown subcomponent accounts for every layout pass.

As a **diagnostic only**, the staged copy of `ChatView` was changed from `VStack` to `LazyVStack`, and its initial wait changed because lazy rows do not all have frames. The forced test then reached 151/151 and the mounted-presentation check in 6.31 s. The normal-layout test, however, reached Store idle in 3.39 s but did not meet the mounted-render check in 60 s: the streaming row was not established as visible by this experimental setup. This is not a safe fix or an equivalent acceptance test; lazy geometry, initial tail positioning, history anchoring and navigation all require a new design and independent verification. Production code was not changed by this experiment. The final staged sources were restored to the production `VStack` after the experiment.

To reproduce the diagnostic, stage the `after` variant with `scripts/stage-transcript-acceptance.py`, build its Release test bundle with testability enabled, and invoke `PiWorkTests.SessionStoreTests/testTranscriptAcceptanceLiveDiagnosis` with `PERF_VARIANT=after`, `PERF_COMPLEX_FIXTURE` set to the fixture path, and `PERF_DIAG_MODE=unmounted`, `mounted` or `forced`. `PERF_DIAG_ROWS`, `PERF_DIAG_HISTORY_PLAIN`, `PERF_DIAG_BODY_PLAIN`, and `PERF_DIAG_TIMEOUT_MS` provide the controls above. Check that exactly one test executed: an invalid XCTest selector can report success with zero tests. The diagnostic build reused the existing staged build directory, so previously built binaries there were replaced; the original measurement logs were not overwritten.

## Comparison and workload

The live-stream reference is **not the original implementation**. The original failed a mounted final-text check (Store sequence 151, expected 9,224 bytes), making a performance ratio invalid. The reference retains the original whole-parent projection and 100-to-300 window, but shares the corrected row-to-parser delivery with the implementation. Both passed the mounted final-text check. The reference is an approximation, not an independent proof of the original performance.

The following numbers describe the **prior implementation, before the latest restoration change**. Native Release, 840 × 640 pt, complex fixture `PiWorkTests/Fixtures/markdown/performance-complex.md`; two samples per variant per workload, A/B/B/A. Mixed windows contain 10 full complex assistant replies, 70 shorter replies and 20 user messages. Dense cold-open contains 80 full complex replies and 20 user messages. Streaming uses about 9.3 KB in approximately 150 nominally 20 ms chunks. Host history is an in-process fake, not network I/O. Forty-eight scenario records were collected; individual records and environment/load logs are under `build/TranscriptAcceptance/performance-prior-freshness/`.

| Median, corrected reference → implementation | Reference | Implementation |
|---|---:|---:|
| Mixed cold open | 26.57 s | 18.74 s |
| Dense cold open | 206.67 s | 155.06 s |
| Cached history coverage | 104.95 s / 300 older sources / 3 moves | 77.27 s / 320 older sources / 4 moves |
| Remote history coverage | 39.06 s / 2 moves | 43.88 s / 3 moves |
| Live stream CPU | 14.26 s | 7.83 s |
| Background stream CPU while reading history | 16.97 s | 1.87 s |

The remote-history median wall time regressed **12.3%** and requires an extra move, narrowly under the predefined 15% gate. Cached coverage differs (300 vs 320), so compare per-source cost as well as raw duration. RSS is cumulative process peak, not per-scenario allocation. Gap measurements combine scheduling and forced layout and are not GPU FPS.

Results are highly sensitive to other workloads and swapping; two observations per configuration do not establish a robust speedup or rule out a material regression. The failed contended run reached sequence 59 rather than 150 within its collection deadline and reported a stale final presentation at that point; it is not proven whether this was only machine load. The passing runs do not erase that finding.

## Verification artifacts and reproduction

- Debug pass: `build/TranscriptAcceptance/full-debug-verified.log`.
- Full Release failure: `build/TranscriptAcceptance/full-release-verified.log`.
- Isolated Release reruns: `build/TranscriptAcceptance/history-release-recheck.log` and `history-release-repeat-{1,2,3}.log`.
- Subsequent full Release pass: `build/TranscriptAcceptance/full-release-recheck.log`.
- Full Release tests require `ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO` with the local ad-hoc signing setup and `-DTRANSCRIPT_ACCEPTANCE` for renderer instrumentation.
- Prior numeric gates, records and logs: `build/TranscriptAcceptance/performance-prior-freshness/results.json` and `summary.md`. Freshness-change test logs: `build/TranscriptAcceptance/full-freshness-{debug-1,release-2,release-3}.log`. These generated files are build artifacts, not a substitute for the failed-run logs.
- `scripts/benchmark-transcript-acceptance.sh <pre-change-source-snapshot>` stages separate binaries. The initial snapshot is `build/TranscriptAcceptance/baseline-source/` in this worktree; preserve it when reproducing.

Outstanding work: verify whether the identified race explains all intermittent history failures, exercise real scrolling and session switching interactively, and repeat performance measurements on an otherwise idle machine. The 100-source limit does not address the dense initial Markdown layout bottleneck.
