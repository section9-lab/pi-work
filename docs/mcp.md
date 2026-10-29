# MCP support

PiWork embeds Pi 1.4.0 and uses its native MCP extension, transports, OAuth implementation,
tool discovery, and execution pipeline. Settings → MCP manages application-level servers.
The isolated configuration is `~/Library/Application Support/pi-work/Agent/mcp.json`.
Repository `.pi/mcp.json` files are not loaded in this first release.

## Configure a server

Add a server and choose STDIO or Streamable HTTP. The form provides a server name,
full command or URL, environment variables or headers, and an optional timeout.
Names use letters, digits, underscores, and hyphens. Command arguments support quoted
paths and empty arguments; commands are executed directly without a shell.
Paste environment variables as a JSON string map or `KEY=value` lines; headers also
accept `Name: value` lines. Duplicate names are rejected, with case-insensitive header checks.

Advanced settings provide a working directory and an optional JSON editor for native
Pi options such as OAuth client configuration and per-tool exposure. Switching between
JSON and the form preserves these settings, enabled state, and stored-secret placeholders.
Chat access and individual read-only tool approvals are in the Permissions disclosure.

```json
{
  "url": "https://example.com/mcp",
  "exposure": "deferred"
}
```

For local services, use an absolute executable path and separate arguments. The service's
runtime (for example Node.js or Python) must be installed. A desktop-launched application
does not necessarily inherit a terminal's PATH. Relative `cwd` values resolve against the
session directory; the standalone connection test uses the home directory as its base.
PiWork does not share MCP Roots automatically: some servers replace their configured
directory allowlist with client roots. Filesystem servers therefore keep the explicit
directories in their command-line configuration during diagnostics and conversations.

Existing JSON files with a top-level `mcpServers` object can be imported. Imports are atomic,
reject duplicate namespaces, and start disabled. Review each command, argument, environment
variable and endpoint before enabling it. Import does not overwrite existing servers.

Saving or enabling a server, or opening the management page with an unchecked enabled
server, automatically starts a temporary diagnostic connection, lists its tools, and cleans
up its process. Refresh retries enabled servers; failed checks are not retried on every poll.
Disabled imports are never started automatically. Diagnostics do not call tools or approve
their use. A successful diagnostic remains visible after that temporary connection closes.
Chat and Work sessions own their live connections; their status takes precedence while open.
Changes reload idle sessions immediately and running sessions after the current turn. Calls
to stale or disabled configurations are blocked before execution.

## Authentication

HTTP servers without an Authorization header can use OAuth. Sign in opens the server's
authorization page in the browser and completes through a local loopback callback. The
interface supports cancellation and a manual callback URL when needed. Pi performs discovery,
PKCE, dynamic or configured client registration, token refresh and callback validation.
Sign out removes local credentials; it does not revoke grants at the provider.

OAuth credentials live in the app's `Agent/mcp-auth.json`. Configuration and credentials use
owner-only file permissions. Saved header, environment and OAuth client-secret values are
redacted in management responses. Keep `<stored-secret>` when editing to retain a value;
replace it to rotate the credential, or remove its field to delete it. Model provider tokens
are not reused for MCP servers.

## Permissions and discovery

- Work **Full access** permits tools from enabled servers.
- Work **Ask** requests approval before each MCP tool or resource call.
- Work **Read only** permits only explicitly approved server tools and native resource reads.
  A server's `readOnlyHint` is informational and never grants permission.
- Chat connects only servers explicitly enabled for Chat, and asks before each MCP call.

After connecting, edit the server to select individual tools approved for read-only access.
Approvals use the tool's complete model-facing identity, including collision-safe names.
The same execution hook covers directly invoked tools and nested calls from another tool.
Cancellation and access-mode changes settle pending approvals through the existing UI.

Servers default to deferred tool discovery via `tool_search`. Pi's `codemode` exposure is
mapped to deferred in this release; Codemode's Worker/WASM execution is not enabled. Explicit
direct and hidden exposure settings remain available. Native MCP resource tools are supported;
legacy SSE and MCP Apps embedded interfaces are not supported.

## ACP and maintenance

ACP v1 `mcpServers` definitions are session-scoped and not written to disk. HTTP capability is
advertised; SSE is not. Client-supplied definitions do not inherit application Chat or read-only
permissions even when they use an application server's name.

The pinned internal management imports are isolated in `AgentHost/src/mcp-native-adapter.ts`,
because Pi's public extension factory does not expose its desktop management primitives.
Review this adapter when upgrading Pi; do not import other internal paths throughout the app.

Run the Agent Host typecheck and tests, both Bun compilation targets, and
`bash scripts/test-native.sh`. The latter builds all production Swift sources using a temporary
SwiftPM project and the pinned MarkdownUI dependency. It omits two existing Xcode-only previews.
With Xcode it runs XCTest; with Command Line Tools it runs the native MCP checks against the
compiled Host. Xcode archive/signing validation remains a separate release check.
