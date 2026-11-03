import { expect, test } from "bun:test";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager, type AgentSession } from "@earendil-works/pi-coding-agent";
import { createPiSessionHandle } from "../src/pi-session-handle.ts";

test("PiWork preserves inactive extension tools and only keeps deferred tools once activated", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-work-loadout-"));
  let handle: Awaited<ReturnType<typeof createPiSessionHandle>> | undefined;
  try {
    await mkdir(join(root, "extensions"));
    await writeFile(join(root, "extensions/fixture.ts"), `
      import { Type } from "typebox";
      export default function (pi) {
        for (const [name, options] of [
          ["fixture_direct", {}], ["fixture_inactive", { defaultActive: false }],
          ["fixture_deferred", { exposure: "deferred" }], ["fixture_hidden", { exposure: "hidden" }]
        ]) pi.registerTool({ name, label: name, description: name, parameters: Type.Object({}), ...options,
          async execute() { return { content: [{ type: "text", text: "fixture" }], details: undefined }; } });
      }
    `);
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    await runtime.setRuntimeApiKey("openai", "synthetic-key");
    let session!: AgentSession;
    handle = await createPiSessionHandle({ sessionManager: SessionManager.inMemory(root), profile: "work", agentDir: root,
      modelRuntime: runtime, settingsManager: SettingsManager.inMemory() }, async (options) => {
      const created = await createAgentSession(options); session = created.session; return created;
    });
    expect(session.getActiveToolNames()).toContain("fixture_direct");
    for (const name of ["fixture_inactive", "fixture_deferred", "fixture_hidden"]) expect(session.getActiveToolNames()).not.toContain(name);
    session.setActiveToolsByName([...session.getActiveToolNames().filter((name) => name !== "fixture_direct"), "fixture_deferred"]);
    handle.setAccessMode("readOnly");
    expect(session.getActiveToolNames()).toContain("fixture_deferred");
    expect(session.getActiveToolNames()).not.toContain("fixture_direct");
    expect(session.getActiveToolNames()).not.toContain("fixture_inactive");
    expect(session.getActiveToolNames()).not.toContain("bash");
    expect(session.getActiveToolNames()).toContain("read");
    await handle.reload();
    expect(session.getActiveToolNames()).toContain("fixture_deferred");
    expect(session.getActiveToolNames()).not.toContain("fixture_direct");
    expect(session.getActiveToolNames()).not.toContain("fixture_inactive");
    expect(session.getActiveToolNames()).not.toContain("fixture_hidden");
  } finally { handle?.dispose(); await rm(root, { recursive: true, force: true }); }
});
