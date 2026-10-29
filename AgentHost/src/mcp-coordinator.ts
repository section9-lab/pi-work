import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  createMcpExtension,
  createToolSearchExtension,
  type ExtensionFactory,
  type LoadedMcpConfig,
  type McpServerConfig,
  type McpServerEntry,
} from "@earendil-works/pi-coding-agent";
import { AccessController, AccessPolicyError } from "./access-policy.ts";
import {
  createDefaultTransport, createMcpToolName, FileAuthStorageBackend, isMcpToolName, loadMcpConfig,
  McpOAuthCredentialStore, McpServerConnection, mcpNamespace, signInMcpServer,
  validateMcpServerConfig, type McpTransportFactory,
} from "./mcp-native-adapter.ts";

const storedSecret = "<stored-secret>";
const maxConfigurationBytes = 256 * 1024;
type JSONObject = Record<string, unknown>;
type ServerPolicy = { allowInChat: boolean; readOnlyTools: string[] };
type ConnectionStatus = "unchecked" | "connecting" | "connected" | "disconnected" | "needs-auth" | "failed";
export type McpToolSnapshot = { name: string; callName: string; description: string; readOnly: boolean };
type ConnectionSnapshot = { status: ConnectionStatus; tools: McpToolSnapshot[]; error?: string };
export type McpServerSnapshot = ConnectionSnapshot & ServerPolicy & {
  name: string; transport: "stdio" | "http"; enabled: boolean;
  configurationJSON: string; canLogin: boolean; signedIn: boolean;
};
export type McpAuthSnapshot = {
  name: string; state: "authorizing" | "success" | "failed" | "cancelled";
  url?: string; error?: string;
};
export type McpSnapshot = { servers: McpServerSnapshot[]; errors: string[]; auth: McpAuthSnapshot | null };

function object(value: unknown): value is JSONObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function policy(value: unknown): ServerPolicy {
  return {
    allowInChat: object(value) && value.allowInChat === true,
    readOnlyTools: object(value) && Array.isArray(value.readOnlyTools)
      ? value.readOnlyTools.filter((item): item is string => typeof item === "string") : [],
  };
}
function parseJSON(value: string): JSONObject {
  if (Buffer.byteLength(value) > maxConfigurationBytes) throw new Error("MCP configuration is too large");
  let parsed: unknown;
  try { parsed = JSON.parse(value.replace(/^\uFEFF/, "")); }
  catch { throw new Error("MCP configuration must be valid JSON"); }
  if (!object(parsed)) throw new Error("MCP configuration must be an object");
  return parsed;
}
function toolsSnapshot(server: string, tools: McpServerConnection["tools"]): McpToolSnapshot[] {
  const names = tools.map((tool) => createMcpToolName(server, tool.name));
  return tools.map((tool) => ({ name: tool.name,
    callName: createMcpToolName(server, tool.name, (name) => names.filter((candidate) => candidate === name).length > 1),
    description: tool.description ?? "", readOnly: tool.annotations?.readOnlyHint === true }));
}
// All env/header values are private, including ordinary-looking values. A
// placeholder round-trips the original secret without returning it to the UI.
function redact(config: McpServerConfig): string {
  const value = structuredClone(config) as unknown as JSONObject;
  for (const key of ["env", "headers"]) {
    if (object(value[key])) value[key] = Object.fromEntries(Object.keys(value[key]).map((name) => [name, storedSecret]));
  }
  if (object(value.oauth) && value.oauth.clientSecret) value.oauth.clientSecret = storedSecret;
  return JSON.stringify(value, null, 2);
}
function restoreSecrets(value: JSONObject, previous?: McpServerConfig): JSONObject {
  const old = previous as unknown as JSONObject | undefined;
  for (const key of ["env", "headers"]) {
    if (!object(value[key])) continue;
    for (const [name, entry] of Object.entries(value[key])) {
      if (entry !== storedSecret) continue;
      const previousValues = old?.[key];
      if (!object(previousValues) || typeof previousValues[name] !== "string") throw new Error("Replace the stored-secret placeholder with a value");
      value[key][name] = previousValues[name];
    }
  }
  if (object(value.oauth) && value.oauth.clientSecret === storedSecret) {
    if (!old || !object(old.oauth) || typeof old.oauth.clientSecret !== "string") throw new Error("OAuth client secret is missing");
    value.oauth.clientSecret = old.oauth.clientSecret;
  }
  return value;
}
function validated(name: string, value: unknown): McpServerConfig {
  const result = validateMcpServerConfig(name, value);
  // Native validation can include invalid values in diagnostics. The editor
  // already shows those values; do not echo secrets onto the protocol stream.
  if (typeof result === "string") throw new Error(`Invalid MCP configuration for ${name}. Check the name, transport and field types.`);
  if ("url" in result && result.auth) throw new Error("Configure MCP authentication separately from model provider accounts");
  return result;
}
function effective(config: McpServerConfig): McpServerConfig {
  const exposure = (value: string | undefined) => !value || value === "codemode" ? "deferred" as const : value;
  return {
    ...config, exposure: exposure(config.exposure) as McpServerConfig["exposure"],
    ...(config.toolExposure ? { toolExposure: Object.fromEntries(Object.entries(config.toolExposure).map(([name, mode]) => [name, exposure(mode)])) as McpServerConfig["toolExposure"] } : {}),
  };
}

export class McpCoordinator {
  private readonly path: string;
  private readonly credentials: McpOAuthCredentialStore;
  private readonly diagnostic = new Map<string, ConnectionSnapshot>();
  private readonly live = new Map<symbol, { name: string; signature: string; snapshot: ConnectionSnapshot; close: () => Promise<void> }>();
  private readonly probes = new Map<string, McpServerConnection>();
  private readonly operations = new Set<Promise<void>>();
  private readonly sessionServers = new Map<string, McpServerEntry[]>();
  private auth: McpAuthSnapshot | null = null;
  private authAbort?: AbortController;
  private authRedirect?: (url: string | undefined) => void;

  constructor(readonly agentDir: string) {
    this.path = join(agentDir, "mcp.json");
    this.credentials = new McpOAuthCredentialStore(new FileAuthStorageBackend(join(agentDir, "mcp-auth.json")), agentDir);
  }

  private document(): JSONObject {
    if (!existsSync(this.path)) return {};
    if (lstatSync(this.path).isSymbolicLink()) throw new Error("MCP configuration must be a regular file");
    return parseJSON(readFileSync(this.path, "utf8"));
  }
  private policies(): JSONObject {
    const document = this.document();
    return object(document.piWork) ? document.piWork : {};
  }
  private entries(): LoadedMcpConfig {
    // First release deliberately loads only application-managed configuration.
    // Opening a repository never authorizes its commands or credentials.
    if (existsSync(this.path) && lstatSync(this.path).isSymbolicLink()) {
      return { servers: [], errors: ["MCP configuration must be a regular file."] };
    }
    const loaded = loadMcpConfig({ agentDir: this.agentDir, cwd: homedir(), projectTrusted: false });
    const servers = loaded.servers.filter((entry) => !("url" in entry.config && entry.config.auth));
    return { ...loaded, servers, errors: loaded.errors.length > 0 || servers.length !== loaded.servers.length
      ? ["A server in mcp.json has invalid configuration. Edit the configuration to repair it."] : [] };
  }
  private write(document: JSONObject): void {
    mkdirSync(this.agentDir, { recursive: true, mode: 0o700 });
    if (existsSync(this.path) && lstatSync(this.path).isSymbolicLink()) throw new Error("MCP configuration must be a regular file");
    const temporary = `${this.path}.${crypto.randomUUID()}.tmp`;
    writeFileSync(temporary, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600, flag: "wx" });
    renameSync(temporary, this.path);
    chmodSync(this.path, 0o600);
  }
  snapshot(): McpSnapshot {
    const loaded = this.entries();
    let policies: JSONObject;
    try { policies = this.policies(); } catch { policies = {}; }
    return {
      servers: loaded.servers.map((entry): McpServerSnapshot => {
        const connections = [...this.live.values()].filter((item) => item.name === entry.name && item.signature === JSON.stringify(effective(entry.config)));
        const active = connections.find((item) => item.snapshot.status === "connected") ?? connections.at(-1);
        const connection = active?.snapshot ?? this.diagnostic.get(entry.name) ?? { status: "unchecked" as const, tools: [] };
        const url = "url" in entry.config ? entry.config.url : undefined;
        const canLogin = Boolean(url && !Object.keys("headers" in entry.config ? entry.config.headers ?? {} : {}).some((key) => key.toLowerCase() === "authorization"));
        return {
          ...connection, ...policy(policies[entry.name]), name: entry.name,
          transport: url ? "http" : "stdio", enabled: entry.config.enabled !== false,
          configurationJSON: redact(entry.config), canLogin,
          signedIn: this.signedIn(entry.name, url),
        };
      }).sort((a, b) => a.name.localeCompare(b.name)),
      errors: loaded.errors, auth: this.auth ? { ...this.auth } : null,
    };
  }
  private signedIn(name: string, url?: string): boolean {
    try { return Boolean(url && this.credentials.tokens(name, url)); }
    catch { return false; }
  }
  save(name: string, configurationJSON: string, serverPolicy: ServerPolicy): void {
    const document = this.document();
    const servers = object(document.mcpServers) ? document.mcpServers : {};
    const previous = this.entries().servers.find((entry) => entry.name === name)?.config;
    const config = validated(name, restoreSecrets(parseJSON(configurationJSON), previous));
    if (Object.keys(servers).some((other) => other !== name && mcpNamespace(other) === mcpNamespace(name))) throw new Error("Another MCP server uses this namespace");
    const oldURL = previous && "url" in previous ? previous.url : undefined;
    const nextURL = "url" in config ? config.url : undefined;
    if (oldURL && oldURL !== nextURL) this.credentials.remove(name, oldURL);
    document.mcpServers = { ...servers, [name]: config };
    document.piWork = { ...(object(document.piWork) ? document.piWork : {}), [name]: policy(serverPolicy) };
    this.write(document);
    this.cancelLogin(name);
    this.closeProbe(name);
    this.diagnostic.delete(name);
  }
  importConfiguration(configurationJSON: string): void {
    const imported = parseJSON(configurationJSON);
    if (!object(imported.mcpServers) || Object.keys(imported.mcpServers).length === 0) throw new Error("Import requires a nonempty mcpServers object");
    const document = this.document();
    const servers = object(document.mcpServers) ? { ...document.mcpServers } : {};
    const namespaces = new Set(Object.keys(servers).map(mcpNamespace));
    for (const [name, raw] of Object.entries(imported.mcpServers)) {
      if (namespaces.has(mcpNamespace(name))) throw new Error(`An MCP server named ${name} already exists`);
      namespaces.add(mcpNamespace(name));
      servers[name] = { ...validated(name, raw), enabled: false };
    }
    // Imported commands remain disabled until the user reviews and enables them.
    this.write({ ...document, mcpServers: servers });
  }
  remove(name: string): void {
    const document = this.document();
    const entry = this.requireEntry(name);
    this.cancelLogin(name);
    if ("url" in entry.config) this.credentials.remove(name, entry.config.url);
    if (object(document.mcpServers)) delete document.mcpServers[name];
    if (object(document.piWork)) delete document.piWork[name];
    this.write(document);
    this.closeProbe(name);
    this.diagnostic.delete(name);
  }
  setEnabled(name: string, enabled: boolean): void {
    const entry = this.requireEntry(name);
    this.save(name, JSON.stringify({ ...entry.config, enabled }), policy(this.policies()[name]));
  }
  private requireEntry(name: string): McpServerEntry {
    const entry = this.entries().servers.find((entry) => entry.name === name);
    if (!entry) throw new Error("MCP server was not found");
    return entry;
  }
  private closeProbe(name: string): void {
    const connection = this.probes.get(name);
    this.probes.delete(name);
    void connection?.close();
  }
  private connection(entry: McpServerEntry): McpServerConnection {
    return new McpServerConnection({
      entry, cwd: homedir(),
      credentials: this.credentials, createTransport: createDefaultTransport, onTools: () => {},
      onChange: (connection) => {
        // A diagnostic intentionally closes its temporary transport. Preserve
        // the check result instead of briefly publishing a false disconnect.
        if (connection.state === "closed") return;
        if (this.probes.get(entry.name) !== connection) return;
        const current = this.entries().servers.find((candidate) => candidate.name === entry.name);
        if (!current || JSON.stringify(current.config) !== JSON.stringify(entry.config)) return;
        this.diagnostic.set(entry.name, {
          status: connection.state,
          tools: toolsSnapshot(entry.name, connection.tools),
          ...(connection.error ? { error: "MCP connection failed. Check the executable, runtime, URL and authentication." } : {}),
        });
      },
    });
  }
  async check(name: string): Promise<void> {
    const entry = this.requireEntry(name);
    if (entry.config.enabled === false) throw new Error("Enable the MCP server before connecting");
    if (this.probes.has(name)) throw new Error("This MCP server is already connecting");
    const connection = this.connection(entry);
    this.probes.set(name, connection);
    this.diagnostic.set(name, { status: "connecting", tools: [] });
    try { await connection.getClient(); }
    catch { /* state and a safe diagnostic are published by onChange */ }
    finally {
      await connection.close();
      if (this.probes.get(name) === connection) this.probes.delete(name);
    }
  }
  startCheck(name: string): void {
    const entry = this.requireEntry(name);
    if (entry.config.enabled === false) throw new Error("Enable the MCP server before connecting");
    if (this.probes.has(name)) throw new Error("This MCP server is already connecting");
    const operation = this.check(name);
    this.operations.add(operation);
    void operation.catch(() => {}).finally(() => this.operations.delete(operation));
  }
  startLogin(name: string): void {
    if (this.auth?.state === "authorizing") throw new Error("Another MCP sign-in is already running");
    const entry = this.requireEntry(name);
    const connection = this.connection(entry);
    if (entry.config.enabled === false || !connection.oauthUrl) throw new Error("Enable an HTTP server without an Authorization header to use OAuth");
    const abort = new AbortController();
    this.authAbort = abort;
    this.auth = { name, state: "authorizing" };
    // Return immediately so the native client can poll, open the browser and cancel.
    const operation = (async () => {
      const deadline = setTimeout(() => abort.abort(), 5 * 60_000);
      const cancelConnection = () => { void connection.close(); };
      abort.signal.addEventListener("abort", cancelConnection, { once: true });
      try {
        // The 401 challenge may point at a non-default protected-resource
        // metadata URL or request an additional scope. Preserve that discovery.
        try { await connection.getClient(); } catch { /* OAuth-required is expected */ }
        await signInMcpServer({
          serverUrl: connection.oauthUrl!, store: this.credentials.forServer(name, connection.oauthUrl!),
          settings: connection.oauthSettings(), challenge: connection.challenge, signal: abort.signal,
          prompt: {
            showAuthorizationUrl: (url) => { this.auth = { name, state: "authorizing", url: url.href }; },
            promptForRedirectUrl: (signal) => new Promise((resolve) => {
              const done = (url?: string) => { signal.removeEventListener("abort", cancelled); this.authRedirect = undefined; resolve(url); };
              const cancelled = () => done();
              this.authRedirect = done;
              if (signal.aborted) done(); else signal.addEventListener("abort", cancelled, { once: true });
            }),
          },
        });
        this.auth = { name, state: "success" };
      } catch {
        this.auth = { name, state: abort.signal.aborted ? "cancelled" : "failed", ...(abort.signal.aborted ? {} : { error: "MCP sign-in failed. Check OAuth configuration and try again." }) };
      } finally {
        clearTimeout(deadline);
        abort.signal.removeEventListener("abort", cancelConnection);
        this.authRedirect = undefined;
        this.authAbort = undefined;
        await connection.close();
      }
    })();
    this.operations.add(operation);
    void operation.then(() => this.operations.delete(operation), () => this.operations.delete(operation));
  }
  completeLogin(url: string): void {
    if (!this.authRedirect) throw new Error("No MCP sign-in is waiting for a callback URL");
    this.authRedirect(url);
  }
  cancelLogin(name?: string): void {
    if (!name || this.auth?.name === name) this.authAbort?.abort();
  }
  logout(name: string): void {
    const entry = this.requireEntry(name);
    this.cancelLogin(name);
    if ("url" in entry.config) this.credentials.remove(name, entry.config.url);
    this.diagnostic.set(name, { status: "needs-auth", tools: [] });
  }

  setSessionServers(sessionId: string, servers: McpServerEntry[]): boolean {
    const changed = JSON.stringify(this.sessionServers.get(sessionId) ?? []) !== JSON.stringify(servers);
    this.sessionServers.set(sessionId, servers);
    return changed;
  }
  extensions(options: { profile: "chat" | "work"; controller: AccessController; servers?: McpServerEntry[]; sessionId?: string }): ExtensionFactory[] {
    if (options.sessionId && options.servers) this.setSessionServers(options.sessionId, options.servers);
    const loaded = (): LoadedMcpConfig => {
      const configured = this.entries();
      const entries = new Map(configured.servers.map((entry) => [mcpNamespace(entry.name), entry]));
      for (const entry of (options.sessionId ? this.sessionServers.get(options.sessionId) : options.servers) ?? []) entries.set(mcpNamespace(entry.name), entry);
      return {
        ...configured, autoEnableCodemode: false,
        servers: [...entries.values()].filter((entry) => options.profile !== "chat" || (entry.source !== "acp-client" && policy(this.policies()[entry.name]).allowInChat))
          .map((entry) => ({ ...entry, config: effective(entry.config) })),
      };
    };
    const security: ExtensionFactory = (pi) => {
      let sessionEntries = new Map<string, string>();
      pi.on("session_start", () => {
        sessionEntries = new Map(loaded().servers.map((entry) => [entry.name, JSON.stringify(entry.config)]));
      });
      pi.on("session_shutdown", (event) => {
        if (options.sessionId && event.reason !== "reload") this.sessionServers.delete(options.sessionId);
      });
      pi.on("tool_call", async (event, ctx) => {
        if (!isMcpToolName(event.toolName)) return;
        try {
          const current = loaded().servers;
          const tool = pi.getAllTools().find((tool) => tool.name === event.toolName);
          const entry = current.find((entry) => tool?.namespace?.name === mcpNamespace(entry.name));
          const resourceTool = !event.toolName.startsWith("mcp__");
          const serverPolicy = entry && entry.source !== "acp-client" ? policy(this.policies()[entry.name]) : policy(undefined);
          const allowed = resourceTool || Boolean(entry && entry.config.enabled !== false);
          if (!allowed) throw new AccessPolicyError("access_denied", "This MCP server is disabled or unavailable in this session");
          const configurationChanged = resourceTool
            ? JSON.stringify([...sessionEntries]) !== JSON.stringify(current.map((entry) => [entry.name, JSON.stringify(entry.config)]))
            : entry && sessionEntries.get(entry.name) !== JSON.stringify(entry.config);
          if (configurationChanged) throw new AccessPolicyError("access_denied", "MCP configuration changed. This session will reconnect after the current turn.");
          await options.controller.authorizeMcp({
            toolCallId: event.toolCallId, toolName: event.toolName, input: event.input,
            signal: ctx.signal, chatAllowed: options.profile === "chat" && (resourceTool || serverPolicy.allowInChat),
            approvedReadOnly: resourceTool || serverPolicy.readOnlyTools.includes(event.toolName),
          });
        } catch (error) {
          return { block: true, reason: error instanceof AccessPolicyError ? error.message : "MCP permission check failed" };
        }
      });
    };
    return [security, createToolSearchExtension(), createMcpExtension({
      loadConfig: loaded, credentials: this.credentials,
      createTransport: this.observedTransport(), logPath: join(this.agentDir, "mcp.log"),
    })];
  }

  private observedTransport(): McpTransportFactory {
    return (entry, cwd, auth) => {
      const transport = createDefaultTransport(entry, cwd, auth);
      const key = Symbol(entry.name);
      const snapshot: ConnectionSnapshot = { status: "connecting", tools: [] };
      this.live.set(key, { name: entry.name, signature: JSON.stringify(entry.config), snapshot, close: () => transport.close() });
      const requests = new Map<string, { method: string; firstPage: boolean }>();
      let listedTools: McpServerConnection["tools"] = [];
      transport.onMessage((message) => {
        if (!("id" in message) || !("result" in message)) return;
        const request = requests.get(String(message.id));
        requests.delete(String(message.id));
        if (request?.method === "initialize") snapshot.status = "connected";
        if (request?.method === "tools/list" && object(message.result) && Array.isArray(message.result.tools)) {
          const tools = message.result.tools.filter(object).filter((tool) => typeof tool.name === "string") as unknown as McpServerConnection["tools"];
          listedTools = request.firstPage ? tools : [...listedTools, ...tools];
          snapshot.tools = toolsSnapshot(entry.name, listedTools);
        }
      });
      transport.onClose(() => {
        this.live.delete(key);
        const current = this.entries().servers.find((candidate) => candidate.name === entry.name);
        if (current && JSON.stringify(effective(current.config)) === JSON.stringify(entry.config)) {
          this.diagnostic.set(entry.name, { ...snapshot, status: snapshot.status === "connected" ? "disconnected" : snapshot.status });
        }
      });
      transport.onError(() => { snapshot.status = "failed"; snapshot.error = "MCP transport failed. Reconnect to check the configuration."; });
      return {
        start: () => transport.start(),
        send: async (message, sendOptions) => {
          if ("id" in message && "method" in message) requests.set(String(message.id), {
            method: message.method, firstPage: !object(message.params) || message.params.cursor === undefined,
          });
          try { await transport.send(message, sendOptions); }
          catch (error) {
            snapshot.status = error instanceof Error && /auth|sign.in|401/i.test(error.name + error.message) ? "needs-auth" : "failed";
            snapshot.error = "MCP connection requires attention. Check authentication or reconnect.";
            throw error;
          }
        },
        close: async () => { this.live.delete(key); await transport.close(); },
        onMessage: (listener) => transport.onMessage(listener), onError: (listener) => transport.onError(listener),
        onClose: (listener) => transport.onClose(listener), setProtocolVersion: (version) => transport.setProtocolVersion?.(version),
      };
    };
  }
  async close(): Promise<void> {
    this.cancelLogin();
    await Promise.all([...this.probes.values()].map((connection) => connection.close()));
    await Promise.all([...this.live.values()].map((connection) => connection.close()));
    await Promise.all(this.operations);
  }
}

/** ACP v1 server definitions are session-scoped and never persisted. */
export function parseACPMcpServers(value: unknown): McpServerEntry[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new Error("mcpServers must be an array");
  const names = new Set<string>();
  return value.map((raw): McpServerEntry => {
    if (!object(raw) || typeof raw.name !== "string") throw new Error("MCP server requires a name");
    const pairs = (value: unknown): Record<string, string> => {
      if (value === undefined) return {};
      if (!Array.isArray(value)) throw new Error("MCP env/headers must be arrays");
      return Object.fromEntries(value.map((pair) => {
        if (!object(pair) || typeof pair.name !== "string" || typeof pair.value !== "string") throw new Error("Invalid MCP env/header entry");
        return [pair.name, pair.value];
      }));
    };
    const config = validated(raw.name, raw.type === "http"
      ? { type: "http", url: raw.url, headers: pairs(raw.headers), exposure: "deferred" }
      : raw.type === undefined || raw.type === "stdio"
        ? { type: "stdio", command: raw.command, args: raw.args, env: pairs(raw.env), exposure: "deferred" }
        : { type: raw.type });
    const namespace = mcpNamespace(raw.name);
    if (names.has(namespace)) throw new Error("Duplicate MCP server namespace");
    names.add(namespace);
    return { name: raw.name, config, scope: "extension", source: "acp-client" };
  });
}
