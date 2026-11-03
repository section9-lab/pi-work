# Pi 1.5 adaptation and validation

PiWork pins `pi-ai`, `pi-coding-agent`, and `pi-tui` to **1.5.0**, with a regenerated Bun lockfile. The app, Host, SDK, Bun and resources are still updated together; Pi's CLI self-update command is not used to modify the bundled runtime. Bun 1.4.2 runs the architecture-neutral AgentHost bundle and also serves as the extension package manager, so the release no longer embeds a second runtime through `bun build --compile`.

## Changes, in validation order

1. **Read-only path authorization.** Authorization uses Pi's own path resolver through `AgentHost/src/pi-path-adapter.ts`, including `@`, `~`, file URLs and macOS filename variants. The resolved path is passed to execution instead of the original alias. Actual read operations additionally recheck their final canonical target, while retaining image detection and resizing. This closes the reproduced project-external read; it is not an operating-system sandbox or a protection against arbitrary trusted extension code/hostile filesystem races.
2. **SDK upgrade and contracts.** Real agent-loop tests cover unbranded JSON Schema coercion, optional null removal, rejected arguments, stored OAuth summarization and macOS shell cancellation. A regression test found that wrapping `agent.streamFunction` hid the SDK's runtime-stream identity and defeated its OAuth summarization fix. Fast mode now composes with `agent.onPayload`, preserving the stream identity and existing payload hooks. MCP fixtures cover CIMD, explicit DCR, unsafe authorization URLs, PKCE, refresh and cancellation.
3. **Tool loadouts and package setup.** Extension availability is no longer confused with activation. Inactive/deferred/hidden tools are not eagerly declared; loaded deferred tools and explicitly deactivated extension tools survive access-mode changes and reload. The built-in tool selection remains governed by PiWork's access mode. Package listing is read-only. Required web capability setup is a separate, single-flight background operation with retryable failures. Local sessions and exports do not wait for installation; failures appear as an extension status. Successful changed setup uses the registry's idle/deferred reload boundary.
4. **Native rendering and progress.** Each tool row retains one input presentation, reusing JSON parsing and edit diffs when only output/status changes. Full input formatting is lazy; diff detail and header statistics share prepared results. Raw tool progress is coalesced over a fixed 50 ms window before normalization and sequence assignment. Non-progress events flush it immediately, and subscription cleanup cancels its timer. Text deltas, approvals and terminal events are never dropped or delayed by this buffer.
5. **Native metadata and package changes.** Standard ACP `usage_update` carries SDK session totals with optional PiWork provenance/response-model metadata. Snapshots preserve the same data. Provider-reported totals are distinguished from estimates only when every recorded usage component reports its total. Tool completion preserves duration and nested-call IDs; recorded duration survives transcript restoration. Plugin update responses distinguish version changes, unchanged versions and unverifiable versions. Changelog previews honor `pi.changelogPath`, select only the installed version interval, are bounded to 256 KiB and cannot escape the package root through traversal or symlinks. The native preview is selectable plain text: it cannot load remote images or execute links/commands.

Additional compatibility fixes:

- Work context and branch instructions use structured system-prompt sections rather than replacing the entire leading prompt.
- A 1M control now requires an SDK catalog window of at least one million tokens, and uses that advertised window as its ceiling. Price tiers alone cannot invent an enlarged window; toggling a supported model down does not lose its catalog capability.
- RTK stdout/stderr use streaming UTF-8 decoding; a real-process fixture covers a Chinese character split across chunks.
- Device-code browser/clipboard preferences survive decoding and projection. Device-code pages do not open automatically; supported actions require a user click. Ordinary browser OAuth retains its existing behavior.
- The elicitation broker cancels requests by session on abort/close/delete, drains requests on shutdown and ignores late responses. An end-to-end Host test cancels an unanswered extension dialog without supplying its response.

## Verification

Each main stage passed its targeted tests, the complete Host suite, TypeScript checking, the relocatable AgentHost bundle build, arm64 runtime recovery checks, and arm64/x64 runtime image smoke tests before the next stage. Native changes additionally passed the app compilation and executable native integration checks in `scripts/test-native.sh`.

Final validation (2026-11-03):

| Check | Result |
| --- | --- |
| Host tests | 267 passed across 28 files |
| AgentHost process and SDK contract tests | Included in the 267-test Host suite |
| Native integration driver | 224 passed; application compilation passed |
| Python build/release utility tests | 51 passed |
| TypeScript and frozen Bun installation | Passed |
| arm64 and x86_64 Bun/runtime package architecture inspection | Passed |
| Bundled Host image upload, resize and read smoke tests | Passed on arm64 and x86_64 |
| Six localization files, shell syntax, Git whitespace checks | Passed |

The system Python initially lacked Pillow. It was installed only under
`/tmp/pi-work-validation/python-venv`; no system Python packages were changed.

Regression entry points:

- `AgentHost/tests/access-policy.test.ts`, `read-only-host.test.ts`
- `AgentHost/tests/sdk-contracts.test.ts`, `mcp-oauth-registration.test.ts`
- `AgentHost/tests/tool-loadout.test.ts`, `extension-packages.test.ts`, `host-process.test.ts`
- `AgentHost/tests/tool-progress.test.ts`, `pi-session-handle.test.ts`
- `AgentHost/tests/package-changelog.test.ts`, `rtk.test.ts`, `acp-extension-ui.test.ts`
- `PiWorkTests/ToolInputPresentationCacheTests.swift` and existing tool/auth tests
- `scripts/ToolPresentationChecks.swift` (runs without Xcode through the native integration driver)

Validation uses temporary projects, synthetic credentials and local provider/MCP servers. It does not intentionally use real provider accounts or incur API charges. Stage logs and compiled artifacts from this implementation session are under `/tmp/pi-work-validation/` and `/tmp/pi-work-*.log`; they are not release artifacts.

## Explicit limits

- Full XCTest and the Xcode release/archive pipeline still require Xcode; the local machine has Command Line Tools only. Native executable checks are not reported as full XCTest.
- The x86_64 Bun bundle and runtime image smoke test run through Rosetta locally; native Intel XCTest, archive/signing/notarization and real-provider compatibility require the Intel CI environment.
- MarkdownUI's current 200 ms streaming parse strategy remains unchanged. No battery-life or end-to-end latency improvement is claimed without profiling. Coalescing progress is not a new hard limit on arbitrary third-party tool payload sizes.
- Fast/1M controls remain conservative; new model IDs are not assumed to support priority service or an enlarged context merely because they appear in the catalog.
- Native changelog previews currently describe explicit in-app updates, not TUI-style next-launch notices for updates performed by another client. Missing or unverifiable changelogs do not fail the package update.
- Arbitrary terminal custom screens and timed-dialog presentation remain outside the native ACP UI's capabilities. Session-level dialog cleanup is implemented; full terminal UI emulation is not.
