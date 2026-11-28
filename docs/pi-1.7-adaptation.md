# Pi 1.7 adaptation and validation

PiWork pins `pi-ai`, `pi-coding-agent`, `pi-tui` and (new) `pi-mcp` to **1.7.0**, with a
regenerated Bun lockfile, and reports `piWorkRuntime.version` **1.3.0**. The app, Host, SDK,
Bun and resources are still updated together; Pi's CLI self-update command is not used to
modify the bundled runtime. This supersedes [Pi 1.5 adaptation](pi-1.5-adaptation.md).

## What the upgrade required

1. **MCP naming helpers moved into `pi-mcp`.** Pi 1.7 no longer exports `mcpNamespace` and
   `createMcpToolName` from `pi-coding-agent`'s internals (`dist/core/mcp-servers.js`,
   `dist/extensions/mcp/tools.js`); both live in `@earendil-works/pi-mcp`'s public API now.
   `AgentHost/src/mcp-native-adapter.ts` imports them from `pi-mcp`, which is pinned to the
   same 1.7.0 as the SDK, so it cannot drift from the version that names tools at runtime.
   The implementations are byte-identical to 1.5 (`mcp__<server>__<tool>`, non-identifier
   characters become `_`, 64-character limit, `sha256(server\0tool)` suffix), so saved MCP
   policies, transcripts and approval prompts keep their names.
   `AgentHost/tests/mcp-naming.test.ts` pins that contract so a future SDK move fails fast.
2. **Extension widget render output is `readonly string[]`.** Since 1.6, `Component.render()`
   returns a readonly array that `Container` caches. `AgentHost/src/acp-extension-ui.ts` now
   accepts `readonly string[]` in `setWidget`'s publish step; the lines are rebuilt through
   `stripTerminalSequences`, so no mutation of Pi's cached array is possible.

## Removals checked against PiWork

- `SettingsManager.getShowCacheMissNotices()` / `setShowCacheMissNotices()` were replaced by
  `getNotices()` / `setNotice()` in 1.6.1, and the install-telemetry accessors and
  `PI_TELEMETRY` were removed in 1.7.0. PiWork calls none of them; settings are patched
  through `settings.update`'s own schema.
- Extension components that mutate `render()` output in place must copy first. PiWork has no
  `Container` subclass that overrides `render()`.
- Tool argument validation runs on `pi-schema` since 1.5.2, so TypeBox features outside JSON
  Schema (`Type.Refine()`, `Type.BigInt()`, `Type.Undefined()`, `Format.Set()`) no longer
  apply. PiWork's tools use plain JSON Schema through `Type.Object`, so behaviour is unchanged.
- `AgentSession.dispose()` stayed synchronous, so the Host's handle teardown is untouched.
  `ModelRuntime.settleCredentialWrites()` is new and optional; PiWork keeps its existing
  shutdown path.

## Verification

| Check | Result |
| --- | --- |
| Host TypeScript check | Passed |
| Host tests (source) | 287 passed across 30 files, 0 failed (856 assertions); 285 before the upgrade plus 2 new naming-contract tests |
| Host tests against the built bundle | 279 passed, 6 failed — the same six cases fail with a bundle rebuilt from the pre-upgrade commit, so they are a pre-existing bundle-mode gap, not a 1.7 regression |
| Bundle build (`AgentHost/scripts/build-host.ts`) | Passed, relocatable 9.5 MB bundle |
| Real-process smoke (`initialize`, `session/list`, `session/preview`, `session/new`, `session/close`, `session/exportHtml`) on a 17.6 MB session written by the 1.5 runtime | Output identical to the 1.5 bundle except the reported `piVersion`/`runtime.version` |
| Packaging, release workflow, appcast, CI dependency unit tests | 51 passed |
| App update, project change, agent runtime recovery checks | Passed |
| Native XCTest | 877 executed, 1 skipped, 0 failures |

## Findings outside this upgrade

- **Packaged HTML export cannot find its template.** `pi-coding-agent` resolves the export
  assets through `getExportTemplateDir()`: `<packageDir>/dist/core/export-html` unless it runs
  as a `bun build --compile` binary. `scripts/package-agent-runtime.py` stages them at
  `export-html/`, so `session/exportHtml` fails with
  `ENOENT ... AgentHost/arm64/dist/core/export-html/template.html`. The shipped 0.1.55 runtime
  fails identically, so this predates the upgrade and is tracked separately.
- **SwiftLint baseline drifted when a baselined file changed size.** Five violations
  (`ChatView.swift`, `ModelProviderSettingsView.swift`, `SessionComposerTests.swift`) quoted an
  older line count in `reason`, so lint reported them as new and `scripts/check-local.sh` failed
  at its last step on a clean pre-upgrade checkout too. Fixed in the same release by replacing
  SwiftLint's `--baseline` with the count-based `scripts/lint-budget.json` gate
  (`scripts/lint_gate.py`); see [lint docs](lint.md).
