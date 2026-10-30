import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

Bun.env.PI_WORK_SKIP_REQUIRED_EXTENSION_INSTALL = "1";

type HostProcess = {
  stdin: Bun.FileSink;
  stdout: ReadableStream<Uint8Array>;
  exited: Promise<number>;
  kill(): void;
};

type StreamIdentity = { sequence?: number; turnId?: string; generationIndex?: number; contentIndex?: number };
type PromptEvent = {
  method: string;
  params: StreamIdentity & {
    update?: { sessionUpdate: string; _meta?: StreamIdentity };
    toolCall?: { _meta?: StreamIdentity };
    phase?: string; content?: string; state?: string;
  };
};

class JSONLineReader {
  private readonly decoder = new TextDecoder();
  private buffered = "";

  constructor(private readonly reader: ReadableStreamDefaultReader<Uint8Array>) {}

  async read(): Promise<any> {
    while (true) {
      const newlineIndex = this.buffered.indexOf("\n");
      if (newlineIndex >= 0) {
        const line = this.buffered.slice(0, newlineIndex);
        this.buffered = this.buffered.slice(newlineIndex + 1);
        return JSON.parse(line);
      }
      const { done, value } = await this.reader.read();
      if (done) throw new Error("Host stdout closed before a complete JSON-RPC record");
      this.buffered += this.decoder.decode(value, { stream: true });
    }
  }
}

async function startHost(environment: Record<string, string> = {}): Promise<{
  child: HostProcess;
  lines: JSONLineReader;
  root: string;
}> {
  const root = mkdtempSync(join(tmpdir(), "pi-work-acp-host-test-"));
  const child = Bun.spawn({
    cmd: environment.PI_WORK_HOST_TEST_BINARY ? [environment.PI_WORK_HOST_TEST_BINARY] : [process.execPath, "run", join(import.meta.dir, "../src/main.ts")],
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...Bun.env, PI_WORK_AGENT_DIR: root, PI_CODING_AGENT_DIR: root, PI_WORK_AUTH_PATH: join(root, "auth.json"), ...environment },
  }) as HostProcess;
  const lines = new JSONLineReader(child.stdout.getReader());
  child.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: "initialize-1",
    method: "initialize",
    params: {
      protocolVersion: 1,
      clientInfo: { name: "pi-work-tests", version: "1" },
      clientCapabilities: {},
    },
  })}\n`);
  await child.stdin.flush();
  const initialize = await lines.read();
  expect(initialize).toMatchObject({
    jsonrpc: "2.0",
    id: "initialize-1",
    result: {
      protocolVersion: 1,
      agentCapabilities: {
        sessionCapabilities: {
          list: {},
          delete: {},
          resume: {},
          close: {},
        },
      },
    },
  });
  return { child, lines, root };
}

async function stopHost(child: HostProcess, root: string): Promise<void> {
  child.stdin.end();
  const deadline = setTimeout(() => child.kill(), 3000);
  try { await child.exited; }
  finally { clearTimeout(deadline); rmSync(root, { recursive: true, force: true }); }
}

describe("ACP agent host process", () => {
  test("negotiates ACP and lists sessions through session/list", async () => {
    const { child, lines, root } = await startHost();
    try {
      const cwd = join(root, "workspace");
      mkdirSync(cwd);
      child.stdin.write(`${JSON.stringify({
        jsonrpc: "2.0",
        id: "sessions-1",
        method: "session/list",
        params: { cwd },
      })}\n`);
      await child.stdin.flush();
      expect(await lines.read()).toMatchObject({
        jsonrpc: "2.0",
        id: "sessions-1",
        result: { sessions: [] },
      });
    } finally {
      await stopHost(child, root);
    }
  });

  test("accepts session/cancel as a notification without emitting a response", async () => {
    const { child, lines, root } = await startHost();
    try {
      const cwd = join(root, "workspace");
      mkdirSync(cwd);
      child.stdin.write(`${JSON.stringify({
        jsonrpc: "2.0",
        method: "session/cancel",
        params: { sessionId: "missing-session" },
      })}\n`);
      child.stdin.write(`${JSON.stringify({
        jsonrpc: "2.0",
        id: "sessions-after-cancel",
        method: "session/list",
        params: { cwd },
      })}\n`);
      await child.stdin.flush();

      expect(await lines.read()).toMatchObject({
        jsonrpc: "2.0",
        id: "sessions-after-cancel",
        result: { sessions: [] },
      });
    } finally {
      await stopHost(child, root);
    }
  });

});

for (const scenario of ["followUp", "steer", "stop"] as const) {
  test(`native running input end-to-end: ${scenario}`, async () => {
    let releaseFirst!: () => void;
    let modelStarted!: () => void;
    const firstGate = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const requested = new Promise<void>((resolve) => { modelStarted = resolve; });
    const requests: unknown[] = [];
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
      if (request.method === "GET") return Response.json({ data: [] });
      requests.push(await request.json());
      if (requests.length === 1) { modelStarted(); await firstGate; }
      const chunks = [
        { id: "fixture", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta: { content: "Done" }, finish_reason: null }] },
        { id: "fixture", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
      ];
      return new Response(chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n",
        { headers: { "Content-Type": "text/event-stream" } });
    } });
    const { child, lines, root } = await startHost();
    const send = async (id: string | undefined, method: string, params: Record<string, unknown>) => {
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...(id ? { id } : {}), method, params })}\n`);
      await child.stdin.flush();
    };
    try {
      writeFileSync(join(root, "models.json"), JSON.stringify({ providers: { fixture: {
        baseUrl: `http://127.0.0.1:${server.port}/v1`, api: "openai-completions", apiKey: "synthetic-key",
        models: [{ id: "fixture", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 1024 }],
      } } }));
      writeFileSync(join(root, "settings.json"), JSON.stringify({ defaultProvider: "fixture", defaultModel: "fixture" }));
      await send("new", "session/new", { cwd: root, mcpServers: [] });
      let created;
      do { created = await lines.read(); } while (created.id !== "new");
      const sessionId = created.result.sessionId;
      await send("run", "session/prompt", { sessionId, prompt: [{ type: "text", text: "initial" }] });
      await requested;
      const behavior = scenario === "steer" ? "steer" : "followUp";
      await send("enqueue", "_piWork/session/enqueueInput", {
        sessionId, inputId: "queued-one", text: "additional instruction", images: [], runningBehavior: behavior,
      });
      const events: any[] = [];
      let record;
      do { record = await lines.read(); events.push(record); } while (record.id !== "enqueue");
      expect(record.result).toEqual({ disposition: "queued" });
      expect(events.some((event) => event.method === "_piWork/session.inputQueueChanged"
        && event.params.inputs.some((input: any) => input.id === "queued-one" && input.behavior === behavior))).toBe(true);
      if (scenario === "stop") {
        await send(undefined, "session/cancel", { sessionId });
        do { record = await lines.read(); events.push(record); }
        while (!record.params?.recoveredInputs?.length);
        expect(record.params.recoveredInputs[0].text).toBe("additional instruction");
      }
      releaseFirst();
      do { record = await lines.read(); events.push(record); } while (record.id !== "run");
      expect(record.error).toBeUndefined();
      const idleEvents = events.filter((event) => event.method === "_piWork/session.stateChanged" && event.params.state === "idle");
      expect(idleEvents).toHaveLength(1);
      if (scenario === "stop") {
        expect(record.result.stopReason).toBe("cancelled");
        expect(requests).toHaveLength(1);
      } else {
        expect(record.result.stopReason).toBe("end_turn");
        expect(requests).toHaveLength(2);
        expect(JSON.stringify(requests[1])).toContain("additional instruction");
        const delivered = events.filter((event) => event.method === "_piWork/session.inputDelivered");
        expect(delivered).toHaveLength(1);
        expect(delivered[0].params.input.id).toBe("queued-one");
      }
    } finally { releaseFirst(); server.stop(true); await stopHost(child, root); }
  }, 15000);
}

test("ACP MCP approval responses are processed while session/prompt waits for completion", async () => {
  const modelServer = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      if (request.method === "GET") return Response.json({ data: [] });
      const body = await request.json() as { messages?: Array<{ role: string; tool_call_id?: string }> };
      const complete = body.messages?.some((message) => message.tool_call_id === "mcp-write");
      const discovered = body.messages?.some((message) => message.tool_call_id === "discover");
      const delta = complete ? { content: "Finished" } : { tool_calls: [{ index: 0, id: discovered ? "mcp-write" : "discover", type: "function", function: {
        name: discovered ? "mcp__fixture__write_record" : "tool_search", arguments: discovered ? "{}" : '{"query":"fixture write record"}',
      } }] };
      const chunks = [
        { id: "model-fixture", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta, finish_reason: null }] },
        { id: "model-fixture", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta: {}, finish_reason: complete ? "stop" : "tool_calls" }] },
      ];
      return new Response(chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "Content-Type": "text/event-stream" } });
    },
  });
  const { child, lines, root } = await startHost(Bun.env.PI_WORK_HOST_TEST_BINARY ? { PI_WORK_HOST_TEST_BINARY: Bun.env.PI_WORK_HOST_TEST_BINARY } : {});
  async function send(id: string, method: string, params: Record<string, unknown>) {
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    await child.stdin.flush();
    while (true) {
      const record = await lines.read();
      if (record.id === id) {
        if (record.error) throw new Error(JSON.stringify(record.error));
        return record.result;
      }
    }
  }
  try {
    writeFileSync(join(root, "models.json"), JSON.stringify({ providers: { fixture: {
      baseUrl: `http://127.0.0.1:${modelServer.port}/v1`, api: "openai-completions", apiKey: "synthetic-model-key",
      models: [{ id: "fixture", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 1024 }],
    } } }));
    writeFileSync(join(root, "settings.json"), JSON.stringify({ defaultProvider: "fixture", defaultModel: "fixture" }));
    const session = await send("new-mcp", "session/new", { cwd: root, mcpServers: [{
      name: "fixture", command: process.execPath, args: [join(import.meta.dir, "fixtures/mcp-server.ts")],
      env: [{ name: "PI_WORK_MCP_TEST_CALL_LOG", value: join(root, "mcp-calls.log") }],
    }] });
    await send("ask-mode", "session/set_mode", { sessionId: session.sessionId, modeId: "ask" });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: "prompt-mcp", method: "session/prompt", params: {
      sessionId: session.sessionId, prompt: [{ type: "text", text: "Use the fixture write tool" }],
    } })}\n`);
    await child.stdin.flush();
    let denied = false;
    const promptEvents: PromptEvent[] = [];
    while (true) {
      const record = await lines.read();
      if (record.method) promptEvents.push(record);
      if (record.method === "session/request_permission") {
        expect(record.params.toolCall.title).toBe("mcp__fixture__write_record");
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: record.id, result: { outcome: { outcome: "selected", optionId: "reject" } } })}\n`);
        await child.stdin.flush();
        denied = true;
      }
      if (record.id === "prompt-mcp") {
        expect(record.error).toBeUndefined();
        expect(record.result.stopReason).toBe("end_turn");
        expect(denied).toBe(true);
        expect(existsSync(join(root, "mcp-calls.log"))).toBe(false);
        const chunks = promptEvents.filter((event) => event.method === "session/update"
          && event.params.update?.sessionUpdate === "agent_message_chunk");
        expect(chunks.length).toBeGreaterThan(0);
        const finished = promptEvents.find((event) => event.method === "_piWork/session.assistantContent"
          && event.params.phase === "end" && event.params.content === "Finished");
        expect(finished).toBeDefined();
        if (!finished) throw new Error("Missing assistant content end");
        for (const chunk of chunks) {
          expect(chunk.params.update?._meta).toMatchObject({
            turnId: finished.params.turnId, generationIndex: finished.params.generationIndex,
            contentIndex: finished.params.contentIndex,
          });
        }
        expect(promptEvents.at(-1)).toMatchObject({ method: "_piWork/session.stateChanged", params: { state: "idle" } });
        const sequences = promptEvents.map((event) => event.params.update?._meta?.sequence
          ?? event.params.toolCall?._meta?.sequence ?? event.params.sequence);
        expect(sequences.every((sequence, index) => Number.isInteger(sequence)
          && (index === 0 || sequence === (sequences[index - 1] ?? 0) + 1))).toBe(true);
        break;
      }
    }
  } finally { modelServer.stop(true); await stopHost(child, root); }
}, 15000);
