import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, relative } from "node:path";
import {
  createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager,
  type AgentSession, type ExtensionFactory,
  type McpServerEntry,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import { AccessController } from "../src/access-policy.ts";
import { McpCoordinator, parseACPMcpServers } from "../src/mcp-coordinator.ts";

const roots: string[] = [];
const coordinators: McpCoordinator[] = [];
const sessions: AgentSession[] = [];
afterEach(async () => {
  for (const session of sessions.splice(0)) session.dispose();
  await Promise.all(coordinators.splice(0).map((coordinator) => coordinator.close()));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});
function setup() {
  const root = mkdtempSync(join(tmpdir(), "pi-work-mcp-"));
  roots.push(root);
  const coordinator = new McpCoordinator(root);
  coordinators.push(coordinator);
  return { root, coordinator };
}
const noPolicy = { allowInChat: false, readOnlyTools: [] };
const stdioConfig = {
  command: process.execPath, args: [join(import.meta.dir, "fixtures/mcp-server.ts")],
  exposure: "deferred", timeout: 2,
};
async function until(predicate: () => boolean, timeout = 5000) {
  const started = Date.now();
  while (!predicate()) {
    if (Date.now() - started > timeout) throw new Error("MCP test timed out");
    await Bun.sleep(10);
  }
}
async function openSession(coordinator: McpCoordinator, controller: AccessController, extra: ExtensionFactory[] = [], options: { servers?: McpServerEntry[]; profile?: "chat" | "work" } = {}) {
  const loader = new DefaultResourceLoader({
    cwd: coordinator.agentDir, agentDir: coordinator.agentDir,
    noExtensions: true,
    extensionFactories: [...coordinator.extensions({ profile: options.profile ?? "work", controller, servers: options.servers }), ...extra],
  });
  await loader.reload();
  const { session } = await createAgentSession({
    cwd: coordinator.agentDir, agentDir: coordinator.agentDir, resourceLoader: loader,
    sessionManager: SessionManager.inMemory(coordinator.agentDir),
    settingsManager: SettingsManager.inMemory(),
    modelRuntime: await ModelRuntime.create({ authPath: join(coordinator.agentDir, "model-auth.json"), refreshOnCreate: false }),
  });
  sessions.push(session);
  await session.bindExtensions({});
  await until(() => session.getAllTools().some((tool) => tool.name === "mcp__fixture__read_record"));
  return session;
}

// Drive Pi's real agent loop with deterministic model responses. Calling a raw
// tool's execute() would skip the agent's beforeToolCall pipeline entirely.
async function runTool(session: AgentSession, name: string, args: Record<string, string | number> = {}, id = "call") {
  const model = { id: "fixture", name: "Fixture", api: "openai-responses" as const, provider: "openai", baseUrl: "https://example.com", reasoning: false,
    input: ["text"] as ["text"], contextWindow: 128000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  await session.modelRuntime.setRuntimeApiKey("openai", "synthetic-test-key");
  await session.setModel(model);
  let first = true;
  session.agent.streamFunction = () => {
    const call = first;
    first = false;
    const stream = createAssistantMessageEventStream();
    const message: AssistantMessage = {
      role: "assistant", api: model.api, provider: model.provider, model: model.id,
      content: call ? [{ type: "toolCall", id, name, arguments: args }] : [{ type: "text", text: "Done" }],
      stopReason: call ? "toolUse" : "stop", timestamp: Date.now(),
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    };
    stream.push({ type: "done", reason: call ? "toolUse" : "stop", message });
    stream.end(message);
    return stream;
  };
  await session.prompt("Run the test tool");
  const result = [...session.messages].reverse().find((message) => message.role === "toolResult" && message.toolCallId === id);
  if (!result || result.role !== "toolResult") throw new Error(`No tool result: ${JSON.stringify(session.agent.state.messages.slice(-3))}`);
  return result;
}

describe("MCP application configuration", () => {
  test("redacts secrets, preserves them on edit, validates before write and restricts permissions", () => {
    const { root, coordinator } = setup();
    coordinator.save("docs", JSON.stringify({ url: "https://example.com/mcp", headers: { Authorization: "Bearer test-secret" }, oauth: { clientSecret: "test-client-secret" } }), noPolicy);
    const first = coordinator.snapshot().servers[0]!;
    expect(first.configurationJSON).not.toContain("test-secret");
    expect(first.configurationJSON).not.toContain("test-client-secret");
    coordinator.save("docs", first.configurationJSON, { allowInChat: true, readOnlyTools: ["mcp__docs__read"] });
    const stored = readFileSync(join(root, "mcp.json"), "utf8");
    expect(stored).toContain("Bearer test-secret");
    expect(statSync(join(root, "mcp.json")).mode & 0o777).toBe(0o600);
    expect(() => coordinator.save("bad", '{"url":42}', noPolicy)).toThrow();
    expect(readFileSync(join(root, "mcp.json"), "utf8")).toBe(stored);
    coordinator.remove("docs");
    expect(coordinator.snapshot().servers).toEqual([]);
  });

  test("imports atomically, starts disabled and rejects colliding namespaces", () => {
    const { coordinator } = setup();
    coordinator.importConfiguration(JSON.stringify({ mcpServers: { "my-tools": stdioConfig } }));
    expect(coordinator.snapshot().servers[0]!.enabled).toBe(false);
    expect(() => coordinator.importConfiguration(JSON.stringify({ mcpServers: { other: stdioConfig, my_tools: stdioConfig } }))).toThrow();
    expect(coordinator.snapshot().servers).toHaveLength(1);
    coordinator.setEnabled("my-tools", true);
    expect(coordinator.snapshot().servers[0]!.enabled).toBe(true);
  });

  test("accepts typed ACP stdio/HTTP servers and rejects SSE or duplicates", () => {
    expect(parseACPMcpServers([
      { name: "local", command: "/bin/server", args: [], env: [{ name: "KEY", value: "synthetic" }] },
      { name: "remote", type: "http", url: "https://example.com/mcp", headers: [] },
    ])).toMatchObject([{ config: { command: "/bin/server", env: { KEY: "synthetic" } } }, { config: { url: "https://example.com/mcp" } }]);
    expect(() => parseACPMcpServers([{ name: "old", type: "sse", url: "https://example.com/sse" }])).toThrow();
    expect(() => parseACPMcpServers([{ name: "a-b", command: "/bin/a" }, { name: "a_b", command: "/bin/b" }])).toThrow();
  });
});

describe("native MCP stdio and permission pipeline", () => {
  test("does not share implicit cwd roots or answer unsolicited roots requests", async () => {
    const { root, coordinator } = setup();
    const log = join(root, "roots.json");
    coordinator.save("fixture", JSON.stringify({ ...stdioConfig, env: { PI_WORK_MCP_TEST_ROOTS_LOG: log } }), noPolicy);
    await coordinator.check("fixture");
    const recorded = JSON.parse(readFileSync(log, "utf8")) as {
      capabilities: Record<string, unknown>;
      response: { result?: unknown; error?: { code: number } };
    };
    expect(coordinator.snapshot().servers[0]!.status).toBe("connected");
    expect(recorded.capabilities).not.toHaveProperty("roots");
    expect(recorded.response).toMatchObject({ error: { code: -32601 } });
    expect(recorded.response).not.toHaveProperty("result");
    expect(JSON.stringify(recorded)).not.toContain(homedir());
  });

  test("connects a real stdio server and discovers tools without an LLM", async () => {
    const { coordinator } = setup();
    coordinator.save("fixture", JSON.stringify(stdioConfig), noPolicy);
    await coordinator.check("fixture");
    expect(coordinator.snapshot().servers[0]).toMatchObject({ status: "connected", tools: [{ name: "read_record", readOnly: true }, { name: "write_record", readOnly: false }] });
  });

  test("editing during an automatic check replaces the old probe without overwriting its successor", async () => {
    const { coordinator } = setup();
    coordinator.save("fixture", JSON.stringify(stdioConfig), noPolicy);
    coordinator.startCheck("fixture");
    coordinator.save("fixture", JSON.stringify({ ...stdioConfig, timeout: 5 }), noPolicy);
    await coordinator.check("fixture");
    // Drain the cancelled predecessor too, so its cleanup cannot erase the new result.
    await coordinator.close();
    expect(coordinator.snapshot().servers[0]).toMatchObject({ status: "connected", tools: [
      { name: "read_record" }, { name: "write_record" },
    ] });
  });

  test("resolves diagnostic relative cwd against the home directory once", async () => {
    const { root, coordinator } = setup();
    coordinator.save("fixture", JSON.stringify({ ...stdioConfig, cwd: relative(homedir(), root) }), noPolicy);
    await coordinator.check("fixture");
    expect(coordinator.snapshot().servers[0]!.status).toBe("connected");
  });

  test("deferred tools are found on demand and explicit read-only policy gates execution", async () => {
    const { root, coordinator } = setup();
    coordinator.save("fixture", JSON.stringify(stdioConfig), { ...noPolicy, readOnlyTools: ["mcp__fixture__read_record"] });
    const controller = new AccessController({ cwd: root, mode: "readOnly" });
    const session = await openSession(coordinator, controller);
    expect(session.getActiveToolNames()).not.toContain("mcp__fixture__read_record");
    await runTool(session, "tool_search", { query: "list MCP resources", limit: 8 }, "resource-search");
    const resources = await runTool(session, "list_mcp_resources", { server: "fixture" }, "resources");
    expect(resources.isError).toBe(false);
    expect(JSON.stringify(resources.content)).toContain("fixture://record");
    await runTool(session, "tool_search", { query: "fixture record", limit: 8 }, "search");
    expect((await runTool(session, "mcp__fixture__read_record", {}, "read"))?.content).toMatchObject([{ type: "text", text: "test record" }]);
    const deniedWrite = await runTool(session, "mcp__fixture__write_record", {}, "write");
    expect(deniedWrite.isError).toBe(true);
    expect(deniedWrite.content).toEqual([{ type: "text", text: "This MCP tool has not been approved for read-only access" }]);
    // Even a server which advertises readOnlyHint is blocked without user approval.
    coordinator.save("fixture", JSON.stringify(stdioConfig), noPolicy);
    expect(await runTool(session, "mcp__fixture__read_record", {}, "read-again")).toMatchObject({ isError: true });
  });

  test("nested calls require approval, denial blocks them, and abort cancels pending approval", async () => {
    const { root, coordinator } = setup();
    coordinator.save("fixture", JSON.stringify(stdioConfig), noPolicy);
    const controller = new AccessController({ cwd: root, mode: "ask" });
    const nested: ExtensionFactory = (pi) => pi.registerTool({
      name: "nested_test", label: "Nested test", description: "Test a nested MCP call", parameters: Type.Object({}),
      execute: async (_id, _params, _signal, _update, ctx) => {
        const result = await ctx.executeTool("mcp__fixture__write_record", {});
        if (result.isError) throw new Error("Nested MCP call was denied or cancelled");
        return result.result;
      },
    });
    const session = await openSession(coordinator, controller, [nested]);
    const approved = runTool(session, "nested_test", {}, "parent");
    await until(() => controller.pendingApprovals().length === 1);
    const approval = controller.pendingApprovals()[0]!;
    expect(approval.toolCallId).toStartWith("parent/");
    controller.resolve(approval.id, "allowOnce");
    expect((await approved)?.content).toMatchObject([{ text: "record written" }]);
    const denied = runTool(session, "nested_test", {}, "denied-parent");
    await until(() => controller.pendingApprovals().length === 1);
    controller.resolve(controller.pendingApprovals()[0]!.id, "deny");
    expect(await denied).toMatchObject({ isError: true });
    const cancelled = runTool(session, "nested_test", {}, "cancelled-parent");
    await until(() => controller.pendingApprovals().length === 1);
    controller.cancelAll();
    expect(await cancelled).toMatchObject({ isError: true });
  });

  test("failed stdio commands report a safe error and Chat does not connect unapproved servers", async () => {
    const { root, coordinator } = setup();
    coordinator.save("broken", JSON.stringify({ command: "/missing/pi-work-mcp-fixture", env: { TOKEN: "must-not-leak" }, timeout: 1 }), noPolicy);
    await coordinator.check("broken");
    expect(coordinator.snapshot().servers[0]?.status).toBe("failed");
    expect(JSON.stringify(coordinator.snapshot())).not.toContain("must-not-leak");
    const loader = new DefaultResourceLoader({ cwd: root, agentDir: root, noExtensions: true,
      extensionFactories: coordinator.extensions({ profile: "chat", controller: new AccessController({ cwd: root, mode: "none" }) }) });
    await loader.reload();
    const { session } = await createAgentSession({ cwd: root, agentDir: root, resourceLoader: loader, settingsManager: SettingsManager.inMemory(), sessionManager: SessionManager.inMemory(root) });
    sessions.push(session);
    await session.bindExtensions({});
    expect(session.getAllTools().filter((tool) => tool.name.startsWith("mcp__"))).toEqual([]);
    expect(existsSync(join(root, "mcp-auth.json"))).toBe(false);
  });

  test("explicitly enabled Chat servers still request approval for each call", async () => {
    const { root, coordinator } = setup();
    coordinator.save("fixture", JSON.stringify(stdioConfig), { allowInChat: true, readOnlyTools: ["mcp__fixture__read_record"] });
    const controller = new AccessController({ cwd: root, mode: "none" });
    const session = await openSession(coordinator, controller, [], { profile: "chat" });
    await runTool(session, "tool_search", { query: "fixture read record" }, "chat-search");
    const result = runTool(session, "mcp__fixture__read_record", {}, "chat-read");
    await until(() => controller.pendingApprovals().length === 1);
    controller.resolve(controller.pendingApprovals()[0]!.id, "deny");
    expect((await result).isError).toBe(true);
  });

  test("ACP overrides do not inherit permissions from an application server with the same name", async () => {
    const { root, coordinator } = setup();
    coordinator.save("fixture", JSON.stringify(stdioConfig), { allowInChat: true, readOnlyTools: ["mcp__fixture__read_record"] });
    const servers = parseACPMcpServers([{ name: "fixture", command: stdioConfig.command, args: stdioConfig.args, env: [] }]);
    const session = await openSession(coordinator, new AccessController({ cwd: root, mode: "readOnly" }), [], { servers });
    await runTool(session, "tool_search", { query: "fixture read record" }, "acp-search");
    expect((await runTool(session, "mcp__fixture__read_record", {}, "acp-read")).isError).toBe(true);
  });
});

describe("native MCP Streamable HTTP and OAuth", () => {
  test("performs discovery, PKCE callback, authenticated connection and logout against a real HTTP server", async () => {
    const { root, coordinator } = setup();
    let challenge = "";
    let issuedToken = false;
    let pkceVerified = false;
    let refreshed = false;
    const server = Bun.serve({
      hostname: "127.0.0.1", port: 0,
      async fetch(request) {
        const url = new URL(request.url);
        const origin = url.origin;
        if (url.pathname === "/custom-resource-metadata") return Response.json({ resource: `${origin}/mcp`, authorization_servers: [origin] });
        if (url.pathname.startsWith("/.well-known/oauth-authorization-server")) return Response.json({
          issuer: origin, authorization_endpoint: `${origin}/authorize`, token_endpoint: `${origin}/token`, registration_endpoint: `${origin}/register`,
          response_types_supported: ["code"], grant_types_supported: ["authorization_code", "refresh_token"], code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none"],
        });
        if (url.pathname === "/register") return Response.json({ client_id: "test-client", ...await request.json() as JSONObject }, { status: 201 });
        if (url.pathname === "/token") {
          const form = new URLSearchParams(await request.text());
          if (form.get("grant_type") === "refresh_token") {
            refreshed = form.get("refresh_token") === "synthetic-refresh";
            return Response.json({ access_token: "synthetic-access", token_type: "Bearer", refresh_token: "rotated-refresh", expires_in: 3600 });
          }
          const verifier = form.get("code_verifier") ?? "";
          pkceVerified = new Bun.CryptoHasher("sha256").update(verifier).digest("base64url") === challenge;
          if (!pkceVerified) return Response.json({ error: "invalid_grant" }, { status: 400 });
          issuedToken = true;
          return Response.json({ access_token: "synthetic-access", token_type: "Bearer", refresh_token: "synthetic-refresh", expires_in: 3600 });
        }
        if (url.pathname !== "/mcp") return new Response(null, { status: 404 });
        if (request.headers.get("authorization") !== "Bearer synthetic-access") return new Response(null, { status: 401, headers: { "WWW-Authenticate": `Bearer resource_metadata="${origin}/custom-resource-metadata"` } });
        if (request.method !== "POST") return new Response(null, { status: 405 });
        const rpc = await request.json() as { id?: string | number; method: string; params?: JSONObject };
        if (rpc.id === undefined) return new Response(null, { status: 202 });
        return Response.json({ jsonrpc: "2.0", id: rpc.id, result: rpc.method === "initialize"
          ? { protocolVersion: rpc.params?.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "http-fixture", version: "1" } }
          : { tools: [{ name: "remote_read", inputSchema: { type: "object" }, description: "A remote read" }] } });
      },
    });
    try {
      coordinator.save("remote", JSON.stringify({ url: `http://127.0.0.1:${server.port}/mcp`, timeout: 2 }), noPolicy);
      await coordinator.check("remote");
      expect(coordinator.snapshot().servers[0]!.status).toBe("needs-auth");
      coordinator.startLogin("remote");
      await until(() => Boolean(coordinator.snapshot().auth?.url) || coordinator.snapshot().auth?.state === "failed");
      const auth = coordinator.snapshot().auth!;
      expect(auth.state).toBe("authorizing");
      const authorizationURL = new URL(auth.url!);
      challenge = authorizationURL.searchParams.get("code_challenge")!;
      const callback = new URL(authorizationURL.searchParams.get("redirect_uri")!);
      callback.searchParams.set("code", "test-code");
      callback.searchParams.set("state", authorizationURL.searchParams.get("state")!);
      expect((await fetch(callback)).ok).toBe(true);
      await until(() => coordinator.snapshot().auth?.state !== "authorizing");
      expect(coordinator.snapshot().auth?.state).toBe("success");
      expect(pkceVerified).toBe(true);
      expect(issuedToken).toBe(true);
      await coordinator.check("remote");
      expect(coordinator.snapshot().servers[0]).toMatchObject({ status: "connected", signedIn: true, tools: [{ name: "remote_read" }] });
      expect(JSON.stringify(coordinator.snapshot())).not.toContain("synthetic-access");
      expect(statSync(join(root, "mcp-auth.json")).mode & 0o777).toBe(0o600);
      const credentials = JSON.parse(readFileSync(join(root, "mcp-auth.json"), "utf8")) as Record<string, JSONObject>;
      for (const state of Object.values(credentials)) state.tokensExpireAt = Date.now() - 1000;
      writeFileSync(join(root, "mcp-auth.json"), JSON.stringify(credentials));
      await coordinator.check("remote");
      expect(refreshed).toBe(true);
      expect(coordinator.snapshot().servers[0]!.status).toBe("connected");
      coordinator.logout("remote");
      expect(coordinator.snapshot().servers[0]!.signedIn).toBe(false);
      coordinator.startLogin("remote");
      coordinator.cancelLogin("remote");
      await until(() => coordinator.snapshot().auth?.state !== "authorizing");
      expect(coordinator.snapshot().auth?.state).toBe("cancelled");
    } finally { server.stop(true); }
  }, 15000);
});

type JSONObject = Record<string, unknown>;
