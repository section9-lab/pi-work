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
- A streaming row subtree should stop propagating geometry invalidation into sibling subtrees (candidate: isolate the streaming row from the shared stack chain, e.g. separate container for live tail), which may complement window virtualization.
- Plan 2 (async event consumption) cannot fix these numbers: the store side already keeps up (receive backlog 0 on this idle machine); the loss happens while the main actor is inside layout.

## Limits

- One observation per scenario; the harness reruns cheaply on the same machine when idle.
- Counts under this profile sum lines, including nested and deduplicated subtrees; ranks, not exact percentages.
- `sample` cannot attribute AppKit/CoreAnimation compositing off-thread costs; ScrollView scrolling smoothness needs separate Instrument run.
