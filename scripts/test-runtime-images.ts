// Exercise the compiled release host, not SDK mocks. Only built-in modules are
// used so CI can remove node_modules from its original build path before running.
import { strict as assert } from "node:assert";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { deflateSync } from "node:zlib";

const executable = resolve(process.argv[2] ?? "");
assert(process.argv[2], "Usage: bun scripts/test-runtime-images.ts /path/to/pi-work-agent-host");
const wasm = readFileSync(join(dirname(executable), "photon_rs_bg.wasm"));
assert.equal(wasm.subarray(0, 4).toString("hex"), "0061736d", "release must contain Photon WASM beside the host");

function crc32(bytes: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function png(width: number, height: number, paddingBytes = 0): Buffer {
  const chunk = (type: string, data: Buffer) => {
    const bytes = Buffer.concat([Buffer.from(type), data]);
    const length = Buffer.alloc(4), crc = Buffer.alloc(4);
    length.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(bytes));
    return Buffer.concat([length, bytes, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 2; // 8-bit RGB
  const pixels = Buffer.alloc((width * 3 + 1) * height, 0x80);
  for (let y = 0; y < height; y++) pixels[y * (width * 3 + 1)] = 0;
  return Buffer.concat([Buffer.from("89504e470d0a1a0a", "hex"), chunk("IHDR", header),
    // A valid private ancillary chunk exercises raw inputs above the old 4.5 MiB
    // app limit without a large pixel allocation or nondeterministic image noise.
    ...(paddingBytes ? [chunk("npAd", Buffer.alloc(paddingBytes))] : []),
    chunk("IDAT", deflateSync(pixels)), chunk("IEND", Buffer.alloc(0))]);
}

const root = mkdtempSync(join(tmpdir(), "pi-work-image-smoke-"));
const small = png(1, 1), large = png(2400, 40, 6 * 1024 * 1024);
const imagePath = join(root, "large.png");
writeFileSync(imagePath, large);
let requestNumber = 0;
let failure: unknown;
let checkedImages = 0;
function checkImage(url: string) {
  assert(url.startsWith("data:image/png;base64,"), "PNG fixture should remain PNG");
  const bytes = Buffer.from(url.split(",")[1]!, "base64");
  assert.equal(bytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  const width = bytes.readUInt32BE(16), height = bytes.readUInt32BE(20);
  assert(width > 0 && width <= 64 && height > 0 && height <= 64,
    `model-specific resize was not applied: ${width}x${height}`);
  assert(Buffer.byteLength(url.split(",")[1]!) <= 32768, "base64 image exceeds model profile");
  checkedImages++;
}
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  async fetch(request) {
    try {
      const body = await request.json() as any;
      const serialized = JSON.stringify(body);
      assert(!serialized.includes("Image omitted"), "host silently discarded an image");
      requestNumber++;
      let delta: any = { content: "Image received" };
      let finishReason = "stop";
      if (requestNumber === 1) {
        const images = body.messages.filter((m: any) => m.role === "user")
          .flatMap((m: any) => m.content).filter((c: any) => c.type === "image_url");
        assert.equal(images.length, 2, "both uploaded images must reach the model");
        images.forEach((c: any) => checkImage(c.image_url.url));
      } else if (requestNumber === 2) {
        assert(body.tools.some((t: any) => t.function.name === "read"), "read tool must be available");
        delta = { tool_calls: [{ index: 0, id: "image-read", type: "function", function: {
          name: "read", arguments: JSON.stringify({ path: imagePath }),
        } }] };
        finishReason = "tool_calls";
      } else {
        assert.equal(requestNumber, 3, "unexpected model request");
        // OpenAI-compatible providers put tool-result image blocks in a user message.
        const images = body.messages.filter((m: any) => m.role === "user")
          .flatMap((m: any) => Array.isArray(m.content) ? m.content : [])
          .filter((c: any) => c.type === "image_url");
        assert.equal(images.length, 1, "read image must reach the model");
        checkImage(images[0].image_url.url);
      }
      const chunks = [
        { id: "image-smoke", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta, finish_reason: null }] },
        { id: "image-smoke", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta: {}, finish_reason: finishReason }] },
      ];
      return new Response(chunks.map(c => `data: ${JSON.stringify(c)}\n\n`).join("") + "data: [DONE]\n\n",
        { headers: { "Content-Type": "text/event-stream" } });
    } catch (error) {
      failure = error;
      return new Response("image smoke assertion failed", { status: 400 });
    }
  },
});
writeFileSync(join(root, "models.json"), JSON.stringify({ providers: { fixture: {
  baseUrl: `http://127.0.0.1:${server.port}/v1`, api: "openai-completions", apiKey: "synthetic-key",
  models: [{ id: "fixture", name: "Fixture", reasoning: false, input: ["text", "image"],
    contextWindow: 128000, maxTokens: 128,
    inputLimits: { images: { resize: { maxWidth: 64, maxHeight: 64, maxBytes: 32768, jpegQuality: 75 } } } }],
} } }));
writeFileSync(join(root, "settings.json"), JSON.stringify({
  defaultProvider: "fixture", defaultModel: "fixture", images: { autoResize: true },
  compaction: { enabled: false }, retry: { enabled: false }, packages: [], extensions: [],
}));
// No real credentials, user packages, or project configuration enter this test.
const child = Bun.spawn({
  cmd: [executable], cwd: root, stdin: "pipe", stdout: "pipe", stderr: "pipe",
  env: { HOME: root, PATH: "/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR: tmpdir(),
    PI_WORK_AGENT_DIR: root, PI_CODING_AGENT_DIR: root, PI_WORK_AUTH_PATH: join(root, "auth.json"),
    PI_WORK_SKIP_REQUIRED_EXTENSION_INSTALL: "1" },
});
const errors = new Response(child.stderr).text();
const reader = child.stdout.getReader();
const decoder = new TextDecoder();
let buffer = "";
async function send(id: string, method: string, params: unknown): Promise<any> {
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  await child.stdin.flush();
  while (true) {
    const newline = buffer.indexOf("\n");
    if (newline >= 0) {
      const record = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      if (record.id === id) {
        if (failure) throw failure;
        assert(!record.error, JSON.stringify(record.error));
        return record.result;
      }
      continue;
    }
    const data = await reader.read();
    assert(!data.done, "host exited before completing the image test");
    buffer += decoder.decode(data.value, { stream: true });
  }
}
const timeout = setTimeout(() => { failure = new Error("Image smoke timed out"); child.kill(); }, 45000);
try {
  await send("init", "initialize", { protocolVersion: 1, clientInfo: { name: "image-smoke", version: "1" }, clientCapabilities: {} });
  const upload = await send("upload-session", "session/new", { cwd: root, mcpServers: [] });
  await send("upload", "session/prompt", { sessionId: upload.sessionId, prompt: [
    { type: "text", text: "Inspect these images" },
    ...[small, large].map(data => ({ type: "image", mimeType: "image/png", data: data.toString("base64") })),
  ] });
  const read = await send("read-session", "session/new", { cwd: root, mcpServers: [] });
  await send("read", "session/prompt", { sessionId: read.sessionId, prompt: [{ type: "text", text: "Read the image" }] });
  if (failure) throw failure;
  assert.equal(requestNumber, 3);
  assert.equal(checkedImages, 3);
  console.log("Runtime images: small/6 MiB raw uploads, model resize profile, and read tool passed");
} finally {
  clearTimeout(timeout);
  child.stdin.end();
  child.kill();
  await child.exited;
  const stderr = await errors;
  if (stderr.trim()) console.error(stderr);
  server.stop(true);
  rmSync(root, { recursive: true, force: true });
}
