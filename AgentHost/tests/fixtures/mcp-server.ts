// A real stdio server, deliberately using no external SDK or user credentials.
export {};
const tools = [
  { name: "read_record", description: "Read a test record", inputSchema: { type: "object", properties: {} }, annotations: { readOnlyHint: true } },
  { name: "write_record", description: "Write a test record", inputSchema: { type: "object", properties: {} } },
];
let buffer = "";
for await (const chunk of Bun.stdin.stream()) {
  buffer += new TextDecoder().decode(chunk);
  while (buffer.includes("\n")) {
    const end = buffer.indexOf("\n");
    const request = JSON.parse(buffer.slice(0, end)) as {
      id?: string | number; method?: string; result?: unknown; error?: unknown;
      params?: { protocolVersion?: string; name?: string; capabilities?: Record<string, unknown> };
    };
    buffer = buffer.slice(end + 1);
    if (request.id === undefined) continue;
    const rootsLog = Bun.env.PI_WORK_MCP_TEST_ROOTS_LOG;
    if (rootsLog && request.id === "probe-roots") {
      await Bun.write(rootsLog, JSON.stringify({ ...JSON.parse(await Bun.file(rootsLog).text()), response: request }));
      continue;
    }
    if (rootsLog && request.method === "initialize") {
      await Bun.write(rootsLog, JSON.stringify({ capabilities: request.params?.capabilities }));
    }
    if (request.method === "tools/call" && Bun.env.PI_WORK_MCP_TEST_CALL_LOG) {
      const log = Bun.file(Bun.env.PI_WORK_MCP_TEST_CALL_LOG);
      await Bun.write(log, `${await log.exists() ? await log.text() : ""}${request.params?.name}\n`);
    }
    const result = request.method === "initialize"
      ? { protocolVersion: request.params?.protocolVersion ?? "2025-11-25", capabilities: { tools: {}, resources: {} }, serverInfo: { name: "fixture", version: "1" } }
      : request.method === "tools/list" ? { tools }
      : request.method === "resources/list" ? { resources: [{ uri: "fixture://record", name: "Test record", mimeType: "text/plain" }] }
      : request.method === "resources/templates/list" ? { resourceTemplates: [] }
      : request.method === "resources/read" ? { contents: [{ uri: "fixture://record", mimeType: "text/plain", text: "resource record" }] }
      : { content: [{ type: "text", text: request.params?.name === "read_record" ? "test record" : "record written" }] };
    await Bun.write(Bun.stdout, `${JSON.stringify({ jsonrpc: "2.0", id: request.id, result })}\n`);
    if (rootsLog && request.method === "initialize") {
      // A misbehaving server asks even when roots were not advertised.
      await Bun.write(Bun.stdout, `${JSON.stringify({ jsonrpc: "2.0", id: "probe-roots", method: "roots/list" })}\n`);
    }
  }
}
