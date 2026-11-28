/**
 * Pi 1.7.0 exposes the session extension publicly, but its desktop management
 * primitives are internal. Keep the version-pinned imports in this one adapter;
 * transport, OAuth discovery, PKCE, refresh and process cleanup stay upstream.
 */
import {
  createDefaultTransport as createPiTransport,
  type McpTransportFactory,
} from "../node_modules/@earendil-works/pi-coding-agent/dist/extensions/mcp/runtime.js";

export {
  McpOAuthCredentialStore,
  McpServerConnection,
  signInMcpServer,
  type McpTransportFactory,
} from "../node_modules/@earendil-works/pi-coding-agent/dist/extensions/mcp/runtime.js";
export {
  loadMcpConfig,
} from "../node_modules/@earendil-works/pi-coding-agent/dist/extensions/mcp/config.js";
export {
  isMcpToolName,
  validateMcpServerConfig,
} from "../node_modules/@earendil-works/pi-coding-agent/dist/core/mcp-servers.js";
export { FileAuthStorageBackend } from "../node_modules/@earendil-works/pi-coding-agent/dist/core/auth-storage.js";
// Pi 1.7 moved the MCP naming helpers out of pi-coding-agent into pi-mcp's
// public API. The implementations are byte-identical to 1.5, so tool names and
// namespaces stay stable for stored sessions and saved server configurations.
export { createMcpToolName, mcpNamespace } from "@earendil-works/pi-mcp";

/**
 * Pi automatically shares cwd as a root. Some servers (including the official
 * Filesystem server) replace their configured allowlist with those roots. The
 * desktop host has no roots consent UI, and diagnostics use the home directory,
 * so do not advertise or answer roots until explicit root selection is supported.
 */
export const createDefaultTransport: McpTransportFactory = (entry, cwd, auth) => {
  const transport = createPiTransport(entry, cwd, auth);
  return {
    start: () => transport.start(),
    send: (message, options) => {
      if ("method" in message && message.method === "initialize" && message.params
        && typeof message.params === "object" && !Array.isArray(message.params) && "capabilities" in message.params) {
        const capabilities = message.params.capabilities;
        if (capabilities && typeof capabilities === "object" && !Array.isArray(capabilities)) {
          const { roots: _roots, ...explicitCapabilities } = capabilities as Record<string, unknown>;
          return transport.send({ ...message, params: { ...message.params, capabilities: explicitCapabilities } }, options);
        }
      }
      return transport.send(message, options);
    },
    close: () => transport.close(),
    onMessage: (listener) => transport.onMessage((message) => {
      if ("method" in message && message.method === "roots/list" && "id" in message) {
        void transport.send({ jsonrpc: "2.0", id: message.id,
          error: { code: -32601, message: "PiWork does not share MCP roots" } }).catch(() => {});
        return;
      }
      listener(message);
    }),
    onError: (listener) => transport.onError(listener),
    onClose: (listener) => transport.onClose(listener),
    setProtocolVersion: (version) => transport.setProtocolVersion?.(version),
  };
};
