# Conversation rendering and energy use

The event reducer consumes every host event in order. UI presentation is intentionally less frequent:

- Text, thinking deltas, tool output updates and usage updates share an 80 ms fixed publication window. This is a throttle, not a debounce: continuous output cannot postpone publication indefinitely.
- Completion, errors, approvals, configuration changes and explicit store operations immediately publish the latest reducer state and cancel any scheduled publication. Store shutdown also flushes received text.
- `recordsPublisher` supplies current snapshots to non-view subscribers. `recordUpdates` identifies changed sessions. Streaming content does not emit the store's global `objectWillChange` unless workspace-visible run state or session identity changes. `ChatView` only invalidates for its active/presented session.
- Unchanged message rows use explicit equality. Expanded history uses a lazy stack, while the most recent 40 messages remain eagerly measured to preserve stable tail anchoring and selection in the live conversation.
- Each Markdown block owns persistent parsed content. Streaming revisions are coalesced over 200 ms; completion flushes immediately. There is no periodic idle timer. Streaming prefixes do not enter the bounded shared Markdown cache on each revision.
- Auto-follow responds to message insertion and measured content height, not event sequence numbers. Scroll requests share a 50 ms window and are cancelled on navigation/disappearance. Manual scroll pause is respected.

## Verification

Regression coverage lives in `SessionStoreTests`, `AssistantMarkdownPresentationTests`, `SessionComposerTests` and `AssistantTimelinePresentationTests`. Run `scripts/test-native.sh`; full XCTest execution requires Xcode, while Command Line Tools can compile the app and run the existing native checks.

For energy comparisons, use the same transcript/model and compare CPU time during sustained generation, then after completion, with the window both visible and hidden. Include a background session, expanded history, long Markdown/code blocks, manual scrolling, approval, stop/error and navigation during generation. Do not infer a battery-life improvement solely from fewer UI publications; profile the built app on the same workload.
