# Streaming Markdown render benchmark

Measures the cost of turning a growing Markdown reply into SwiftUI views, for
three strategies:

| Variant | What it does |
|---|---|
| `A whole document` | The shipped path: one `Markdown` view per reply. Every tick rebuilds and re-lays out the whole document. |
| `B block memo` | One memoized view per frozen top-level block (`.equatable()`), active tail last, eager `VStack`. |
| `C block memo lazy` | Same segments in a `LazyVStack`, so blocks outside the viewport are never measured. |
| `D block memo window` | Eager stack that mounts only the newest 6 blocks; older blocks become height-exact placeholders measured while mounted (the transcript's row-virtualization pattern, one level down). |
| `control` | No ingest; reports harness overhead. |

The harness compiles the **shipped** `StreamingMarkdownAccumulator.swift`
(incl. `StreamingMarkdownSegment`/`StreamingMarkdownSegmenter`) via
`scripts/benchmark-markdown-streaming.sh`, verifies that per-segment parsing
reproduces the full document's CommonMark output, and then streams the fixture
in ~31-character chunks into a bottom-pinned `ScrollView` inside an offscreen
`NSWindow`. One "tick" is: mutate the published text, let SwiftUI flush, force
layout, measure wall time.

## Run

```bash
scripts/benchmark-markdown-streaming.sh
scripts/benchmark-markdown-streaming.sh path/to/other.md
```

## Recorded result (M-series Mac, Release, 2026-11-15)

Fixture: `PiWorkTests/Fixtures/markdown/performance-complex.md`, chunk ≈ 31 chars.

| Fixture | A whole document | B memo + VStack | C memo + LazyVStack | D memo + window |
|---|---:|---:|---:|---:|
| 4.6 KB (12 segments) | 71.6 ms/tick · 7.1 s | 32.7 ms/tick · 3.3 s | **3.9 ms/tick · 0.62 s** | 10.0 ms/tick · 1.5 s |
| 9.2 KB (24 segments) | 83.2 ms/tick · 21.5 s | 41.1 ms/tick · 15.1 s | **2.6 ms/tick · 1.0 s** | 12.4 ms/tick · 5.1 s |

Measured with the app's `Theme.gitHub` applied to every variant. Document-height stability (same content, measured at top / middle / bottom of the
scroll view; the transcript anchor math reads row frames in document
coordinates):

| Variant | 4.6 KB drift | 9.2 KB drift |
|---|---:|---:|
| A whole document | 0 pt | 0 pt |
| B memo + VStack | 0 pt | 0 pt |
| C memo + LazyVStack | **28 pt** | **595 pt** |
| D memo + window | 0 pt | 0 pt |

A `LazyVStack` reports a smaller document until the reader scrolls into it, so
every anchor/history calculation sees a moving coordinate system. D gets most
of the speed with exact geometry.

Control (no ingest): 0.01–0.02 ms/tick, so the numbers are content work, not
harness noise. Segmentation matched a full parse exactly in both fixtures.

## Limitations

- Absolute values are an offscreen, window-hosted proxy; in-app cadence (200 ms
  coalescing, viewport gating) changes the totals, not the ratio.
- B/C/D show that memoization alone is worth ~2×, and memoization **plus** some
  form of virtualization is worth ~8–20×. SwiftUI has no retained layout tree,
  so an eager stack still measures every child on each tick.
- C is the fastest but not geometry-safe (see the drift table); D is the
  geometry-safe option and is what the app exposes as
  `PIWORK_MARKDOWN_BLOCK_MEMO=3`.
- D's placeholders reproduce each block's measured height, so its total document
  height can differ from a fully mounted layout by about 1.5 pt per replaced
  block (5180 vs 5214 pt on the 9.2 KB fixture). It does not change while
  scrolling, which is what anchor math depends on.
- Absolute numbers come from an offscreen window; in-app cadence (200 ms
  coalescing, viewport gating) changes totals, not ratios.
