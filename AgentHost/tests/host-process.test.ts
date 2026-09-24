import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

Bun.env.PI_WORK_SKIP_REQUIRED_EXTENSION_INSTALL = "1";

type HostProcess = {
  stdin: Bun.FileSink;
  stdout: ReadableStream<Uint8Array>;
  exited: Promise<number>;
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
    cmd: [process.execPath, "run", join(import.meta.dir, "../src/main.ts")],
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...Bun.env, ...environment },
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
  await child.exited;
  rmSync(root, { recursive: true, force: true });
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
