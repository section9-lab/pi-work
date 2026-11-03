import { expect, test } from "bun:test";
import { mkdtemp, rm, writeFile, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager,
  type AgentSession, type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { createAssistantMessageEventStream, createProvider, type AssistantMessage, type JsonObject } from "@earendil-works/pi-ai";
import { PiSessionHandle } from "../src/pi-session-handle.ts";
import { AccessController, createPolicyControlledTools } from "../src/access-policy.ts";

const model = { id: "fixture", name: "Fixture", api: "openai-responses" as const, provider: "openai",
  baseUrl: "https://example.com", reasoning: false, input: ["text"] as ["text"], contextWindow: 128000,
  maxTokens: 100, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };

async function withSession(tools: ToolDefinition[], run: (session: AgentSession) => Promise<void>) {
  const root = await mkdtemp(join(tmpdir(), "pi-work-sdk-contract-"));
  let session: AgentSession | undefined;
  try {
    const loader = new DefaultResourceLoader({ cwd: root, agentDir: root, noExtensions: true, noSkills: true });
    await loader.reload();
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    await runtime.setRuntimeApiKey("openai", "synthetic-key");
    ({ session } = await createAgentSession({ cwd: root, agentDir: root, resourceLoader: loader,
      modelRuntime: runtime, sessionManager: SessionManager.inMemory(root), settingsManager: SettingsManager.inMemory(), customTools: tools }));
    await session.setModel(model);
    session.setActiveToolsByName(tools.map((tool) => tool.name));
    await run(session);
  } finally { session?.dispose(); await rm(root, { recursive: true, force: true }); }
}

async function callTool(session: AgentSession, args: JsonObject) {
  let first = true;
  session.agent.streamFunction = () => {
    const call = first; first = false;
    const stream = createAssistantMessageEventStream();
    const message: AssistantMessage = { role: "assistant", api: model.api, provider: model.provider, model: model.id,
      responseModel: "physical-fixture",
      content: call ? [{ type: "toolCall", id: "contract-call", name: "plain_json", arguments: args }] : [{ type: "text", text: "Done" }],
      stopReason: call ? "toolUse" : "stop", timestamp: Date.now(),
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0.25, totalFromProvider: true } } };
    stream.push({ type: "done", reason: call ? "toolUse" : "stop", message }); stream.end(message); return stream;
  };
  await session.prompt("Run the synthetic tool");
  return [...session.messages].reverse().find((message) => message.role === "toolResult");
}

function plainTool(execute: (input: unknown) => void): ToolDefinition {
  return { name: "plain_json", label: "Plain JSON", description: "Schema contract fixture",
    // Deliberately unbranded JSON Schema, as returned by an MCP server.
    parameters: { type: "object", properties: { limit: { type: "number" }, names: { type: "array", items: { type: "string" } }, note: { type: "string" } }, required: ["limit", "names"] } as never,
    async execute(_id, input) { execute(input); return { content: [{ type: "text", text: "Executed" }], details: undefined }; } };
}

test("plain JSON Schema tools receive coerced arguments and omit optional null values", async () => {
  let received: unknown;
  await withSession([plainTool((input) => { received = input; })], async (session) => {
    const result = await callTool(session, { limit: "2", names: "one", note: null });
    expect(received).toEqual({ limit: 2, names: ["one"] });
    expect(result).toMatchObject({ isError: false });
  });
});

test("session usage preserves billed totals and the provider's actual response model", async () => {
  await withSession([plainTool(() => {})], async (session) => {
    const handle = new PiSessionHandle(session, session.sessionManager);
    const events: unknown[] = [];
    const unsubscribe = handle.subscribe((event) => events.push(event));
    try {
      await callTool(session, { limit: 2, names: [] });
      expect(handle.snapshot()).toMatchObject({ usage: {
        cost: { amount: 0.5, currency: "USD", source: "provider" }, responseModel: "physical-fixture",
      } });
      expect(events).toContainEqual(expect.objectContaining({ type: "usageChanged" }));
      expect(handle.snapshot().messages.filter((message) => message.role === "assistant")[0])
        .toMatchObject({ responseModel: "physical-fixture" });
    } finally { unsubscribe(); handle.dispose(); }
  });
});

test("invalid tool arguments never execute and report the pi-schema validation failure", async () => {
  let executed = false;
  await withSession([plainTool(() => { executed = true; })], async (session) => {
    const result = await callTool(session, { names: [] });
    expect(executed).toBe(false);
    expect(result).toMatchObject({ isError: true, content: [{ type: "text", text: expect.stringContaining("- limit: missing") }] });
  });
});

test("PiWork session compaction preserves stored OAuth instead of treating its token as an API key", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-work-oauth-summary-"));
  let session: AgentSession | undefined;
  try {
    const credential = { type: "oauth" as const, access: "synthetic-oauth-access", refresh: "synthetic-refresh", expires: Date.now() + 3600000 };
    const authPath = join(root, "auth.json");
    await writeFile(authPath, JSON.stringify({ "fixture-oauth": credential }));
    const runtime = await ModelRuntime.create({ authPath, modelsPath: null, refreshOnCreate: false });
    const fixtureModel = { ...model, provider: "fixture-oauth" };
    const stream = () => {
      const events = createAssistantMessageEventStream();
      const message: AssistantMessage = { role: "assistant", api: model.api, provider: "fixture-oauth", model: model.id,
        content: [{ type: "text", text: "Synthetic conversation summary" }], stopReason: "stop", timestamp: Date.now(),
        usage: { input: 2, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 4,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
      events.push({ type: "done", reason: "stop", message }); events.end(message); return events;
    };
    runtime.registerNativeProvider(createProvider({ id: "fixture-oauth", models: [fixtureModel],
      auth: {
        apiKey: { name: "Fixture API key", async resolve({ credential }) {
          if (credential?.key) throw new Error("OAuth token was incorrectly passed as an explicit API key");
          return undefined;
        } },
        oauth: { name: "Fixture OAuth", async login() { return credential; }, async refresh(value) { return value; },
          async toAuth(value) { return { apiKey: value.access }; } },
      }, api: { stream, streamSimple: stream } }));
    const manager = SessionManager.inMemory(root);
    for (let i = 0; i < 4; i++) {
      manager.appendMessage({ role: "user", content: `Synthetic conversation ${i}: ${"detail ".repeat(200)}`, timestamp: Date.now() });
      manager.appendMessage({ role: "assistant", api: model.api, provider: "fixture-oauth", model: model.id,
        content: [{ type: "text", text: "Synthetic reply" }], stopReason: "stop", timestamp: Date.now(),
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
    }
    const loader = new DefaultResourceLoader({ cwd: root, agentDir: root, noExtensions: true, noSkills: true });
    await loader.reload();
    ({ session } = await createAgentSession({ cwd: root, agentDir: root, model: fixtureModel, modelRuntime: runtime,
      sessionManager: manager, resourceLoader: loader, settingsManager: SettingsManager.inMemory({
        compaction: { enabled: true, keepRecentTokens: 1, reserveTokens: 100 }, retry: { enabled: false },
      }) }));
    const handle = new PiSessionHandle(session, manager);
    try {
      const summary = await session.compact();
      expect(summary.summary).toContain("Synthetic conversation summary");
    } finally { handle.dispose(); }
  } finally { session?.dispose(); await rm(root, { recursive: true, force: true }); }
});

test("macOS shell cancellation does not execute a subsequent command", async () => {
  if (process.platform !== "darwin") return;
  const root = await mkdtemp(join(tmpdir(), "pi-work-shell-cancel-"));
  const abort = new AbortController();
  try {
    const started = join(root, "started"), unwanted = join(root, "unwanted");
    const controller = new AccessController({ cwd: root, mode: "full" });
    const bash = createPolicyControlledTools(root, controller).find((tool) => tool.name === "bash")!;
    const execution = bash.execute("cancel-shell", {
      command: `printf ready > ${JSON.stringify(started)}; sleep 30; printf escaped > ${JSON.stringify(unwanted)}`,
    }, abort.signal, undefined, { cwd: root, sessionManager: SessionManager.inMemory(root), thinkingLevel: "off" } as never);
    // Attach before abort so rejection is always observed.
    const completion = execution.then(() => false, () => true);
    for (let attempt = 0; attempt < 200; attempt++) {
      if (await access(started).then(() => true, () => false)) break;
      await Bun.sleep(10);
    }
    await access(started);
    abort.abort();
    expect(await completion).toBe(true);
    await Bun.sleep(100);
    expect(await access(unwanted).then(() => true, () => false)).toBe(false);
  } finally { abort.abort(); await rm(root, { recursive: true, force: true }); }
}, 10000);
