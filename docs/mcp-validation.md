# MCP live validation — 2026-10-29

Four services were installed and enabled in the local PiWork test application.
The official server packages are installed separately under
`~/Library/Application Support/pi-work/MCPServers/`; they are not application dependencies.
The configuration lives in the application's `Agent/mcp.json`.

| Service | Version / endpoint | Transport | Discovered tools | Verified operations |
| --- | --- | --- | --- | --- |
| [Filesystem](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem) | `@modelcontextprotocol/server-filesystem@2.1.0` | stdio, existing Node.js 24 | 14 | List, write, read; reject access outside the configured sandbox |
| [Sequential Thinking](https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking) | `@modelcontextprotocol/server-sequential-thinking@2.0.0` | stdio, existing Node.js 24 | 1 | Execute one synthetic compatibility check |
| [Microsoft Learn](https://learn.microsoft.com/en-us/training/support/mcp-developer-reference) | `https://learn.microsoft.com/api/mcp` | Streamable HTTP | 3 | Search Azure Blob Storage documentation and fetch a public documentation page |
| [Context7](https://context7.com/docs/installation) | `https://mcp.context7.com/mcp` | Streamable HTTP | 2 | Resolve TanStack Query and retrieve `invalidateQueries` / `queryKey` documentation |

Filesystem exposes only `MCPServers/sandbox`, containing disposable validation files.
The services are available to Work. Chat access and permanent read-only tool approvals
remain off; permission tests used an isolated configuration.

## Live results

All 13 checks passed using the production PiWork MCP coordinator and Pi AgentSession
execution loop. Deterministic model responses triggered actual MCP calls, avoiding paid
model requests; these checks do not evaluate model tool selection.

1. Deferred MCP tools are inactive before discovery.
2. `tool_search` discovers and activates installed tools.
3. Filesystem lists the configured sandbox.
4. Filesystem writes a file through MCP.
5. Filesystem reads the written contents.
6. Filesystem refuses `/etc/hosts`, outside the sandbox.
7. Sequential Thinking executes over stdio.
8. Microsoft Learn returns public documentation search results over HTTP.
9. Microsoft Learn fetches the requested documentation.
10. Read-only mode permits an explicitly approved read tool.
11. Read-only mode rejects a write; the target file is never created.
12. Ask mode rejects a denied write; the target file is never created.
13. Ask mode executes an approved write once.

The packaged Agent Host separately connected to all three installed services through
its ACP management API and discovered the same 18 tools. The native management page
was checked with these installed configurations.

## Context7 application verification

Context7 was added through the native structured HTTP form and connected without an API
key for this check. Its installed configuration retained default permissions: Work enabled,
Chat disabled, no permanent read-only approvals. The application discovers two tools:
`resolve-library-id` and `query-docs`.

The packaged PiWork Host completed `tool_search` → `resolve-library-id` → `query-docs`
against the real remote endpoint, using deterministic model responses to select those calls.
Ask mode requested permission for both Context7 tools; both were approved once. The result
contained real TanStack Query documentation, including `invalidateQueries` and `queryKey`.

A separate GUI check used the application's existing GPT‑6.1 Sol model. It independently
selected and called both tools, resolved `/tanstack/query/v5.90.3`, and cited the
[TanStack Query v5 invalidations guide](https://github.com/tanstack/query/blob/v5.90.3/docs/framework/react/guides/invalidations-from-mutations.md).
The final regression repeated discovery and both calls automatically with the existing
session permissions. All three steps completed, the answer appeared once, and the composer
returned to its idle state. These prompts requested only public library documentation;
the resulting tool steps did not read or modify project files.

## Issue found and fixed

Pi's implicit MCP Roots advertised the current working directory. The official
Filesystem server uses client roots to replace its command-line directory allowlist,
which caused the configured sandbox to become unavailable during conversations and
could expose the home directory during a diagnostic connection.

The desktop transport now omits the unapproved Roots capability and rejects
unsolicited `roots/list` requests. The server retains its configured directories.
A real stdio regression test checks both the advertised capabilities and the rejection.

The MCP interface uses upstream Lucide icons, distributed as template PDFs with their
original SVGs and license. Images are loaded explicitly from the app bundle. No icon
library dependency was added.

The configuration interface was subsequently redesigned around a structured form:
transport, name, full command or URL, environment/header rows, timeout, and collapsible
advanced configuration and permissions. The list provides search, connection status,
tool disclosures and per-server menus. GUI checks covered transport switching, dynamic
header rows, required-field validation, Save availability, Escape dismissal, and the
installed services' connection tests. Enabled configurations are now checked automatically
on save, enable and initial management-page load. Disabled imports remain unchecked. Checks
perform handshake and tool discovery only, and do not invoke tools. A regression covers
editing configuration while its previous check is still in flight.

After restarting the updated test application, opening MCP settings automatically marked
all four installed servers connected (20 tools total), without clicking a connection-test
button. The native list displayed Context7 2, Filesystem 14, Microsoft Learn 3 and
Sequential Thinking 1.

The real Context7 conversation also exposed an ACP streaming defect: converted chunks lost
their generation and sequence metadata, causing duplicate final text and stale running
state. The bridge now preserves stream identity and forwards terminal state/error events.
Native prompt requests wait for the whole turn, including approvals, instead of timing out
after 30 seconds. Cancellation, host termination and normal management-request deadlines
remain in effect. Regression checks replay the wire stream through the production native
decoder/reducer and exercise request cancellation and management deadlines.

## Build and regression checks

- TypeScript strict typecheck and 206 Agent Host tests passed.
- Native Swift application compiled successfully with Command Line Tools.
- 45 native checks passed, including command quoting, secret and OAuth preservation,
  advanced JSON round-trips, header paste and duplicate detection, structured form saves
  through the real Host, automatic checks, ACP stream completion, cancellation,
  narrow layouts and light/dark editor sizing.
- ARM64 and x64 Agent Host binaries built successfully.
- All 3 packaged Host process integration tests and 67 runtime package checks passed.
- OAuth discovery, PKCE, refresh, cancellation and logout remain covered by the local
  OAuth issuer integration tests. These installed services did not require OAuth;
  no third-party account authorization was performed for this live check.

The full Xcode XCTest runner and Archive remain unavailable on this machine.
