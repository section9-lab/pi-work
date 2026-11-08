# Conversation rendering and energy use

The event reducer consumes every delivered host event in order. Raw tool progress is coalesced in the Host over a fixed 50 ms window, before normalization and sequence assignment. Every non-progress event flushes the buffer; text deltas, approvals and terminal events are never coalesced. UI presentation is intentionally less frequent:

- Text, thinking deltas, tool output updates and usage updates share an 80 ms fixed publication window. This is a throttle, not a debounce: continuous output cannot postpone publication indefinitely.
- Completion, errors, approvals, configuration changes and explicit store operations immediately publish the latest reducer state and cancel any scheduled publication. Store shutdown also flushes received text.
- `recordsPublisher` supplies current snapshots to non-view subscribers. `recordUpdates` identifies changed sessions. Streaming content does not emit the store's global `objectWillChange` unless workspace-visible run state or session identity changes. `ChatView` only invalidates for its active/presented session.
- Each tool row retains one input presentation keyed by its name, raw input and summary. Output/status updates reuse it; edit header statistics and expanded details share their computed diffs. Full input formatting is lazy, and arbitrary ACP diffs use a one-entry per-view cache.
- Unchanged message rows use explicit equality. Expanded history uses a lazy stack, while the most recent 40 messages remain eagerly measured to preserve stable tail anchoring and selection in the live conversation.
- Token deltas are appended to a per-part buffer and materialized once per 80 ms publication window (or before a structural event). The published record is unchanged; the per-token full-string copies in both `transcript` and `messages` are gone. Snapshot repair discards any buffered delta so stale text cannot land on a newer projection.
- An assistant row derives its blocks and metadata anchor from one part scan per body pass. Message attachments decode once into a Retina-sized thumbnail cache instead of re-decoding `Data` in every body pass, and on-demand tool output keeps a 16-entry/2 MB LRU.
- Each Markdown block owns persistent parsed content. Streaming revisions are coalesced over 200 ms; completion flushes immediately. There is no periodic idle timer. Streaming prefixes do not enter the bounded shared Markdown cache on each revision.
- Auto-follow responds to message insertion and measured content height, not event sequence numbers. Scroll requests share a 50 ms window and are cancelled on navigation/disappearance. Manual scroll pause is respected.

## Verification

Regression coverage lives in `SessionStoreTests`, `SessionStoreReducerTests`, `AssistantMarkdownPresentationTests`, `SessionComposerTests`, `MessageImageThumbnailCacheTests` and `AssistantTimelinePresentationTests`. Run `scripts/test-native.sh`; full XCTest execution requires Xcode, while Command Line Tools can compile the app and run the existing native checks.

`scripts/benchmark-streaming-append.sh` runs the opt-in token-path scaling guard (`PERF_STREAMING_APPEND=1`). It compares 10k vs 40k deltas with a fixed number of publication flushes and prints the ratio plus the saved per-token copy reference; this isolates the append path from wall-clock publication cadence.

For energy comparisons, use the same transcript/model and compare CPU time during sustained generation, then after completion, with the window both visible and hidden. Include a background session, expanded history, long Markdown/code blocks, manual scrolling, approval, stop/error and navigation during generation. Do not infer a battery-life improvement solely from fewer UI publications; profile the built app on the same workload.
