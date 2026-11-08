# Completion stall profile — 2026-11-08

Status: focused profile and two staged experiments on the ~1.05 s publish tail
that remains after window 48. Production behavior was not changed.

## Where it appears

`forced-mixed-3` (three history rows, complex live reply) has a smooth streaming
phase (p95 gap ≈ 19–21 ms, no receive backlog) but ends with a single 0.95–1.10 s
gap. Every mounted scenario had the same tail, independent of history size and
window size.

## Profile

Release bundle from the staged `after` sources, 840 × 640, fake host. `sample`
ran for 2 s starting 2.4 s after `LIVE_DIAG_START`, covering input completion and
the tail. Main-thread call graph (1,430 samples):

| Frame | Samples |
|---|---:|
| `NSHostingView.beginTransaction` | 870 |
| `GraphHost.flushTransactions` | 869 |
| `AG::Graph::UpdateStack::update()` | 864 |
| `LayoutEngineBox.childGeometries` | 544 |
| `GeometryReaderLayout` → `ScrollViewLayoutComputer` → `UnaryLayout` | 506 |
| `StyledTextLayoutEngine.sizeThatFits` | max 2 |
| `MarkdownContent` / `MarkdownUI` / `cmark` | **0** |
| `SessionStore.receive` | 1–2 |

The tail is a SwiftUI layout transaction. The hot path runs through the outer
`GeometryReader`/`ScrollViewLayoutComputer` content measurement, not Markdown
parsing or CoreText typesetting.

## Experiment A: finalize incremental content instead of a full reparse

Staged completion now reuses the frozen-prefix/tail content instead of calling
`AssistantMarkdownCache.content(for:)` and replacing every block.

| Scenario | Lag before → after | gap_max before → after | CPU before → after |
|---|---:|---:|---:|
| forced-mixed-3 | 1066 → 953 ms | 1069 → 953 ms | 1811 → 1725 ms |
| mounted-mixed-1000 | 1046 → 931 ms | 1050 → 934 ms | 2014 → 2116 ms |
| forced-mixed-1000 | 1036 → 920 ms | 1039 → 920 ms | 2330 → 2157 ms |

The final full parse accounts for roughly 0.1 s of the tail. The remaining
~0.9 s is still layout.

## Experiment B: skip parent structural invalidation

Staged `ChatView` stopped calling `transcriptPresentation.invalidate()` on
structural updates; rows already refresh through their own
`TranscriptMessagePresentation` subscription.

| forced-mixed-3 | Result |
|---|---:|
| publish lag | 885 ms |
| CPU | 2985 ms (vs 1725 ms) |

Lag improved slightly but CPU regressed ~73%. Rejected.

## Experiment C: remove the outer GeometryReader — negative

The staged transcript returned `ScrollViewReader` directly and reported the
viewport size through a background preference instead of wrapping the content in
`GeometryReader`.

| Scenario | Publish lag | CPU |
|---|---:|---:|
| forced-mixed-3 | 3777 ms | 7015 ms |
| mounted-mixed-1000 | 6194 ms | 9381 ms |
| forced-mixed-1000 | 13744 ms | 17057 ms |

The outer `GeometryReader` is load-bearing: it supplies the ScrollView's size
proposal. Removing it caused runaway layout, not a smaller tail. Rejected.

## Experiment D: skip the final content update — confirms the cause, not shippable

Staged completion kept the last streaming content and skipped the final
`MarkdownContent` replacement. The final chunks are therefore missing; this is a
diagnostic, not a shippable state.

| Scenario | Publish lag | CPU |
|---|---:|---:|
| forced-mixed-3 | 26 ms | 999 ms |
| mounted-mixed-1000 | 53 ms | 1301 ms |
| forced-mixed-1000 | 56 ms | 1426 ms |

The tail disappears entirely. Every part of the ~1 s stall is the final content
update, not the terminal event itself.

## Experiment E: stable segments plus a changing tail — no improvement

The accumulator exposed its frozen chunks and last tail; the view rendered one
`Markdown` per frozen segment plus a separate tail `Markdown`, including at
completion.

| Scenario | Publish lag | CPU |
|---|---:|---:|
| forced-mixed-3 | 1103 ms | 2085 ms |
| mounted-mixed-1000 | 1097 ms | 2347 ms |
| forced-mixed-1000 | 1101 ms | 2755 ms |

Stable block segments did not help. Any content update to the completed row
still causes the ScrollView/row layout transaction; the cost is not the parser or
the identity of unaffected blocks.

## Interpretation and next experiments

- The completion tail is not parsing. It is the first full layout of the
  completed complex row through the outer GeometryReader/ScrollView content
  measurement.
- Keeping the incremental content removes only the parse portion; the layout
  transaction remains.
- The next experiments should target that layout boundary rather than Markdown
  parsing:
  1. Narrow the completed row's layout identity. Removing the outer
     GeometryReader outright is not viable (Experiment C).
  2. Avoid replacing the completed row's whole block tree at the terminal
     update (the incremental content still produces a new `MarkdownContent`
     value; separate block identity/hosting may let SwiftUI reuse unchanged
     blocks).
  3. Re-test the separate-host idea specifically at completion; the earlier
     isolation experiments were measured during streaming, not this tail.
  4. Investigate per-block height caching or a TextKit 2 viewport layout, so the
     completed row does not re-measure its entire block tree through the shared
     ScrollView. Segmenting the SwiftUI views alone (Experiment E) is not enough.

Artifacts: `build/TranscriptAcceptance/stall-profile/`,
`build/TranscriptAcceptance/stall-finalize-incremental-2026-11-08/`,
`build/TranscriptAcceptance/stall-no-projection-2026-11-08/`.

## Limits

- One observation per configuration on a machine with load ≈ 3.5–4.0 and swap in
  use. `sample` aggregates all threads; the table is the extracted main-thread
  call graph.
- The staged experiments were not committed. The staged bundle was restored to
  production sources after measurement.
