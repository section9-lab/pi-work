# Streaming bottleneck localization — 2026-11-04

Machine context: otherwise idle (1-minute load near 2, 4 GB swap configured with ~2.5 GB used, previously ~18 GB), Release diagnosis binaries, 840 × 640 pt surface. Single observation per scenario; retest conclusions, not repeats. Artifacts in `build/TranscriptAcceptance/perf-probe-{a,b}/`.

## Decomposition by scenario

| History | Live body | Mode | Publish lag | Process CPU | Publish rounds |
|---|---|---|---:|---:|---:|
| complex×1000 | complex | unmounted | 4 ms | 0.21 s | 38 |
| complex×1000 | complex | mounted | 2607 ms | 5.22 s | 6 |
| plain×1000 | complex | forced | 203 ms | 2.25 s | 19 |
| complex×1000 | complex | forced | 3122 ms | 5.80 s | 6 |
| complex×3 | complex | forced | 1341 ms | 3.77 s | 11 |
| complex×3 | plain | forced | 27 ms | 0.74 s | — |
| complex×1000 | plain | forced | 203 ms* | 2.25 s* | 19* |

*The last row is `forced-plain-history-1000` (plain history, plain live body); my duplicate scenario name for the same configuration was removed from the registry.

Published rounds (`publishedReducerState` invocations) collapse from 38 to 6 when the main actor is blocked — publication itself starves alongside event consumption.

## Where the time goes (sample call graph)

- Non-kernel top-of-stack samples are dominated by SwiftUI layout machinery: `UnaryLayoutEngine.childPlacement(at:)`, `UnaryLayoutEngine/ViewLayoutEngine/LayoutEngineBox.sizeThatFits`, `AGGraphGetInputValue`, `AG::Graph::propagate_dirty`, `LayoutProxy.size(in:)`, plus `swift_retain/release`, `swift_beginAccess`, `_platform_memmove`. This distribution repeats in both mounted and forced profiles.
- Typesetting is NOT the dominant cost: `StyledTextLayoutEngine.sizeThatFits` ancestor sums are 213–250 lines (≈1–4% of layout shares), `CoreTypesetter` 15–25.
- Markdown parsing is absent from the hot ancestors (`MarkdownContent`/`MarkdownUI`: zero lines) — the parser and its cache are not the bottleneck.
- Off-main threads were mostly idle (`__workq_kernreturn`, `mach_msg2_trap`); there is no background CPU work competing.

## Interpretation

The cost centroid is re-running the whole-window stack layout: on every streaming publish (coalesced ~200 ms), the non-lazy `VStack` re-computes `sizeThatFits`/`placeChildren` chains for every displayed row, including unchanged siblings, through the `GeometryReader`/`ScrollViewReader`/stack hierarchy. Evidence:

- Complex history rows scale with window size: complex×1000 adds ≈2.9 s lag over plain×1000 while displayed rows are always 100 (window is fixed at 100 when sources exceed it); complex×3 adds little.
- With few history rows, the growing live reply itself is the dominant element: complex vs plain live body at complex×3 differs by ≈1.3 s vs ≈27 ms.
- Ancestor shares rank `StackLayout.placeChildren` ≫ text layout engines, confirming structural relayout rather than text work.

So the bottleneck is **per-publish window-wide layout invalidation of unchanged sibling rows**, i.e. streaming updates invalidate the parent geometry chain, not per-row content parsing.

## Consequences for the fix direction

- Window virtualization (Plan 1) attacking this relayout directly is the right lever; narrower "make Markdown faster" work (parser, caching, text rendering) is NOT supported by the data.
- Plan 2 (async event consumption) cannot fix these numbers: the store side already keeps up (receive backlog 0 on this idle machine); the loss happens while the main actor is inside layout.

## Container-level isolation experiment: negative result

A first implementation of the isolation idea split the row list into segment containers so the streaming row owns its own subtree (`TranscriptStreamingIsolation`, one `VStack` per segment, unchanged row order and identity). It passed the full 788-test Debug suite. Under the same idle-machine conditions the diagnosis matrix showed a **regression**, not a win:

| Scenario (complex×1000, streaming live) | Baseline container A/B | Isolated containers |
|---|---:|---:|
| mounted-mixed-1000 publish lag | 2194 ms | 4292 ms |
| forced-mixed-1000 publish lag | 2362 ms | 4608 ms |
| forced-mixed-3 publish lag | 919 ms | ~1082 ms |

Baseline was re-measured right before/after the experiment on the same machine (`build/TranscriptAcceptance/perf-baseline-b/`, `perf-isolation-prof/`). The recursive stack summary explains the extra cost: within 15,973 samples of `StackLayout.placeChildren`, 13,912 sit in `LayoutEngineBox.explicitAlignment(_:)` — the nested segment containers added one more alignment-query boundary per row without cutting the per-publish whole-stack placement. The per-publish cost is re-resolving the entire stack's placement/alignment, not merely the streaming row's subtree, so ownership separation via plain nested containers does not remove it.

The production change was reverted after this experiment; the harness, the records in `perf-isolation-{a,prof}` and the demo remain as documentation. Next levers must remove the per-publish full-stack placement itself (true window virtualization, or moving the streaming reply out of the shared layout graph entirely, e.g. a separately-hosted view at the tail), measured against the same matrix.

## Separate-hosted streaming row experiment: unresolved, and a stronger lead

The second isolation attempt moved the streaming row into its own `NSHostingView` (own view graph) inside the shared flow via `NSViewRepresentable`, with an outer frame preference replicating the row's anchor key so anchors still resolve. Debug transcript tests passed. The 00:04–00:06 measurements on the same idle machine were mixed and noisy:

- forced-mixed-1000: 1342 ms and 2786 ms (baseline-b: 2362 ms)
- mounted-mixed-1000: 3500 ms and 3437 ms (baseline-b: 2194 ms)
- forced-mixed-3: 1544 ms and 2156 ms (baseline-b: 919 ms)

Sampling during mounted and forced runs shows the decisive fact: the `StackLayout.placeChildren` recursive sweep **persists** (28k samples with 1,000-row history; 37k with only 3 history rows) even though the growing reply now lives in a separate graph. A whole-stack placement re-run on every publish is therefore not caused by the streaming row's geometry at all. The remaining mechanism consistent with all three experiments: every coalesced publish re-evaluates the transcript body, and the re-created wrapper values (row backgrounds, preference GeometryReaders, equatable boundaries) invalidate the cached layout attributes of every sibling subtree — one row of complex Markdown is re-built per publish even when verbatim identical.

The hosting-isolation production change was reverted (integration risks remain: environment and preferences do not cross the hosting boundary), and this experiment is recorded for reproduction. The strongest next lever is to keep every sibling subtree byte-stable across content-only publishes — either by full session view-isolation (one host per window segment, updates driven by row-owned observers) or by completing the row-owned transport so content-only publishes never re-create sibling view values. Both must be measured with the same matrix and a re-measured same-session baseline.

## Limits

- One observation per scenario; the harness reruns cheaply on the same machine when idle.
- Counts under this profile sum lines, including nested and deduplicated subtrees; ranks, not exact percentages.
- `sample` cannot attribute AppKit/CoreAnimation compositing off-thread costs; ScrollView scrolling smoothness needs separate Instrument run.
