import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// Exercise the real ACP host, provider parser, argument validator and tool
// implementation. The only fake is the external model; no real files or keys.
test("read-only ACP sessions never return project-external path aliases to the model", async () => {
  const root = mkdtempSync(join(tmpdir(), "pi-work-read-only-host-"));
  const project = join(root, "project"), outside = join(root, "outside");
  mkdirSync(project); mkdirSync(outside);
  const marker = "SYNTHETIC_EXTERNAL_CONTENT_MUST_NOT_REACH_MODEL";
  const fixture = join(outside, "fixture.txt");
  writeFileSync(fixture, marker);
  writeFileSync(join(project, "inside.txt"), "AUTHORIZED_INTERNAL_CONTENT");
  const paths = ["../outside/fixture.txt", "@../outside/fixture.txt", `@${fixture}`,
    pathToFileURL(fixture).href, "~/outside/fixture.txt", "@inside.txt"];
  const results: string[] = [];
  let requests = 0;
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    if (request.method === "GET") return Response.json({ data: [] });
    const body = await request.json() as { messages: Array<{ role: string; content: unknown }> };
    const index = Math.floor(requests / 2);
    const call = requests++ % 2 === 0;
    if (!call) results.push(JSON.stringify(body.messages.filter((message) => message.role === "tool")));
    const delta = call
      ? { tool_calls: [{ index: 0, id: `read-${index}`, type: "function", function: {
          name: "read", arguments: JSON.stringify({ path: paths[index] }),
        } }] }
      : { content: "Done" };
    const chunks = [
      { id: "fixture", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta, finish_reason: null }] },
      { id: "fixture", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta: {}, finish_reason: call ? "tool_calls" : "stop" }] },
    ];
    return new Response(chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n",
      { headers: { "Content-Type": "text/event-stream" } });
  } });
  writeFileSync(join(root, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${server.port}/v1`, api: "openai-completions", apiKey: "synthetic-key",
    models: [{ id: "fixture", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 128 }],
  } } }));
  writeFileSync(join(root, "settings.json"), JSON.stringify({ defaultProvider: "fixture", defaultModel: "fixture",
    compaction: { enabled: false }, retry: { enabled: false }, packages: [], extensions: [] }));
  const binary = Bun.env.PI_WORK_HOST_TEST_BINARY;
  const child = Bun.spawn({
    cmd: binary ? [binary] : [process.execPath, "run", join(import.meta.dir, "../src/main.ts")],
    cwd: project, stdin: "pipe", stdout: "pipe", stderr: "pipe",
    env: { HOME: root, PATH: "/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR: tmpdir(), PI_OFFLINE: "1",
      PI_WORK_AGENT_DIR: root, PI_CODING_AGENT_DIR: root, PI_WORK_AUTH_PATH: join(root, "auth.json"),
      PI_WORK_SKIP_REQUIRED_EXTENSION_INSTALL: "1" },
  });
  const errors = new Response(child.stderr).text();
  const reader = child.stdout.getReader(), decoder = new TextDecoder();
  let buffer = "";
  async function send(id: string, method: string, params: Record<string, unknown>): Promise<any> {
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    await child.stdin.flush();
    while (true) {
      const newline = buffer.indexOf("\n");
      if (newline >= 0) {
        const record = JSON.parse(buffer.slice(0, newline)); buffer = buffer.slice(newline + 1);
        if (record.id === id) {
          if (record.error) throw new Error(JSON.stringify(record.error));
          return record.result;
        }
      } else {
        const next = await reader.read();
        if (next.done) throw new Error(`Host exited: ${await errors}`);
        buffer += decoder.decode(next.value, { stream: true });
      }
    }
  }
  const timeout = setTimeout(() => child.kill(), 12000);
  try {
    await send("init", "initialize", { protocolVersion: 1, clientInfo: { name: "read-only-test", version: "1" }, clientCapabilities: {} });
    for (const [index] of paths.entries()) {
      const session = await send(`new-${index}`, "session/new", { cwd: project, mcpServers: [] });
      await send(`mode-${index}`, "session/set_mode", { sessionId: session.sessionId, modeId: "readOnly" });
      await send(`prompt-${index}`, "session/prompt", { sessionId: session.sessionId,
        prompt: [{ type: "text", text: "Read the synthetic fixture" }] });
    }
    expect(results).toHaveLength(paths.length);
    for (const result of results.slice(0, -1)) {
      expect(result).toContain("outside the project");
      expect(result).not.toContain(marker);
    }
    expect(results.at(-1)).toContain("AUTHORIZED_INTERNAL_CONTENT");
  } finally {
    clearTimeout(timeout); child.stdin.end(); child.kill(); await child.exited;
    await errors; server.stop(true); rmSync(root, { recursive: true, force: true });
  }
}, 15000);
