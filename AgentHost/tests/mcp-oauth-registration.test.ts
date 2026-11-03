import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { McpCoordinator } from "../src/mcp-coordinator.ts";

for (const scenario of ["auto", "dcr", "unsafe-endpoint"] as const) {
  test(`MCP OAuth registration: ${scenario}`, async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-work-mcp-registration-"));
    const coordinator = new McpCoordinator(root);
    let registered = false;
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
      const url = new URL(request.url), origin = url.origin;
      if (url.pathname === "/resource-metadata") return Response.json({ resource: `${origin}/mcp`, authorization_servers: [origin] });
      if (url.pathname.startsWith("/.well-known/")) return Response.json({
        issuer: origin, authorization_endpoint: scenario === "unsafe-endpoint" ? "file:///tmp/must-not-open" : `${origin}/authorize`,
        token_endpoint: `${origin}/token`, registration_endpoint: `${origin}/register`,
        response_types_supported: ["code"], grant_types_supported: ["authorization_code"],
        code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none"],
        client_id_metadata_document_supported: true, authorization_response_iss_parameter_supported: true,
      });
      if (url.pathname === "/register") {
        registered = true;
        return Response.json({ ...await request.json() as object, client_id: "fixture-dcr" }, { status: 201 });
      }
      return new Response(null, { status: 401, headers: { "WWW-Authenticate": `Bearer resource_metadata="${origin}/resource-metadata"` } });
    } });
    try {
      coordinator.save("fixture", JSON.stringify({ url: `http://127.0.0.1:${server.port}/mcp`, timeout: 1,
        oauth: { clientRegistration: scenario === "dcr" ? "dcr" : "auto" } }), { allowInChat: false, readOnlyTools: [] });
      coordinator.startLogin("fixture");
      for (let i = 0; i < 500; i++) {
        const auth = coordinator.snapshot().auth;
        if (auth?.url || auth?.state === "failed") break;
        await Bun.sleep(10);
      }
      const auth = coordinator.snapshot().auth;
      if (scenario === "unsafe-endpoint") {
        expect(auth).toMatchObject({ state: "failed" });
        expect(auth?.url).toBeUndefined();
      } else {
        expect(auth?.state).toBe("authorizing");
        const url = new URL(auth!.url!);
        expect(url.searchParams.get("client_id")).toBe(scenario === "auto" ? "https://pi.dev/oauth/client.json" : "fixture-dcr");
        expect(registered).toBe(scenario === "dcr");
      }
    } finally {
      coordinator.cancelLogin(); await coordinator.close(); server.stop(true);
      await rm(root, { recursive: true, force: true });
    }
  }, 10000);
}
