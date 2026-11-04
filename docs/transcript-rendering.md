# Bounded transcript rendering

The chat keeps **100 visible source messages**, not 100 fully expanded tool steps.
Earlier data stays in `SessionStore`; moving the window does not delete history.
The default movement is 80 sources (20 overlap), reduced when necessary to keep
visible sources. This differs from the earlier illustrative 60/40 HTML demo.

## Delivery

- `SessionTranscriptUpdate` separates structural changes from append-only text.
  The fast path requires the exact existing current assistant message and text
  part, contiguous sequence, one text part, and a running matching turn. New
  blocks, other generations, tools, mixed protocols and terminal events use the
  structural path. Existing Store publishers retain their semantics.
- `TranscriptPresentationCache` caches source membership and bounded projections.
  A real published invalidation replaces the discarded generation-counter read.
- Retained row models filter content packets by exact message ID. Structural
  packets also refresh same-ID snapshot repairs and older generations. Cached
  raw source/index checks avoid repeated lookup and timestamp conversion.
  Passive subscriptions are not the same as historical row updates: unrelated
  content packets publish nothing to those rows.
- A mounted `AssistantMarkdownPresentation` subscribes directly to its row's
  snapshot and text-block identity, including tagged-thinking response blocks.
  It does not rely on a nested parent `onChange` to deliver the final text.
  The 200 ms streaming coalescing remains; completion/error flushes immediately.
  Source-bound renderers ignore potentially older parent text properties.
- Grouped rows keep the **complete projected group**, never a single raw source.
  Stable tool-group view keys and session-scoped expansion preferences preserve
  retained controls/details across window boundaries. Session identity resets
  the transcript subtree even when two conversations reuse message IDs.

## History and scrolling

Row and tool-part geometry is measured in document coordinates. Current viewport
coordinates are derived from the native scroll position, including before the
next SwiftUI preference update. Navigation captures visible source/part offsets;
restoration does not enqueue another deferred `scrollTo` after an exact native
correction. History transitions disable implicit row movement animations.

One page is prefetched when a user moves near the loaded history boundary.
Prefetch does not move the pinned window. Foreground callers share the same
Store request and single merge. Responses are checked against session, revision
and cursor; shutdown/removal cancels outstanding loads. Background failures keep
current history intact and allow an explicit retry.

## Verification

`TranscriptPresentationTests`, `TranscriptIntegrationTests`, navigation tests and
existing native history tests cover bounded coverage, identity, filtering,
terminal delivery, complex mounted Markdown, tagged thinking, session swaps,
merged groups, exact offsets, shared requests, shutdown and prefetch coverage.

Read-only weak renderer diagnostics compile only for Debug or
`-DTRANSCRIPT_ACCEPTANCE`; a normal Release build contains no diagnostic registry.
They verify live presentation text, not GPU pixels/FPS.

For production before/after performance use
`scripts/benchmark-transcript-acceptance.sh <pre-change-source-snapshot>`.
Historical `markdown-isolation` scripts require their matching pre-implementation
sources and describe the earlier experimental prototype, not the shipped path.
See `docs/performance/transcript-acceptance-2026-11-04.md` for acceptance results
and limitations.
