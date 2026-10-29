import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { AccessController } from "../src/access-policy.ts";
import { ComputerUseCoordinator, type ComputerUseRuntime } from "../src/computer-use.ts";

class Runtime implements ComputerUseRuntime {
  starts = 0;
  stops = 0;
  prepared = 0;
  granted = true;
  attribution = "helper-app";
  async prepare() { this.prepared += 1; }
  async start() { this.starts += 1; }
  async stop() { this.stops += 1; }
  async command(): Promise<Record<string, unknown>> {
    return { accessibility: this.granted, screenRecordingCapturable: this.granted,
      screenRecordingPreflight: this.granted, source: { attribution: this.attribution } };
  }
}

function fixture(supported = true) {
  const directory = mkdtempSync(join(tmpdir(), "piwork-computer-test-"));
  const runtime = new Runtime();
  const coordinator = new ComputerUseCoordinator(directory, { supported, runtime });
  return { directory, runtime, coordinator, cleanup: async () => {
    await coordinator.dispose(); rmSync(directory, { recursive: true, force: true });
  } };
}
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

describe("Computer use lifecycle and access", () => {
  test("registered upstream actions reject historical or foreign state before touching the desktop", async () => {
    const f = fixture();
    try {
      await f.coordinator.setEnabled(true);
      const tools: ToolDefinition[] = [];
      await f.coordinator.extension(new AccessController({ cwd: f.directory, mode: "full" }), "work")({
        registerTool: (tool: ToolDefinition) => { tools.push(tool); },
      } as unknown as ExtensionAPI);
      const action = tools.find((tool) => tool.name === "act_ui")!;
      const outcome = await action.execute("stale", { stateId: "historical-or-foreign",
        actions: [{ action: "click", x: 10, y: 10 }] }, undefined, undefined,
        { sessionManager: { getSessionId: () => "session-two" } } as unknown as ExtensionToolContext)
        .then(() => "unexpected success", (error: unknown) => error instanceof Error ? error.message : String(error));
      expect(outcome).toContain("Observe the target again");
      expect(f.coordinator.snapshot().activeCalls).toBe(0);
    } finally { await f.cleanup(); }
  });

  test("macOS 13 and disabled snapshots never prepare or start a helper", async () => {
    const f = fixture(false);
    try {
      expect((await f.coordinator.check()).status).toBe("unsupported");
      await expect(f.coordinator.setEnabled(true)).rejects.toThrow("macOS 14");
      expect(f.runtime.prepared).toBe(0);
      expect(f.runtime.starts).toBe(0);
    } finally { await f.cleanup(); }
  });

  test("enable intent persists separately from permission readiness", async () => {
    const f = fixture();
    try {
      f.runtime.granted = false;
      expect(await f.coordinator.setEnabled(true)).toMatchObject({ enabled: true, status: "setupRequired" });
      expect(JSON.parse(readFileSync(join(f.directory, "computer-use.json"), "utf8"))).toEqual({ enabled: true });
      expect(f.coordinator.available("act_ui", "full")).toBe(false);
      f.runtime.granted = true;
      expect((await f.coordinator.recheck()).status).toBe("ready");
      expect(f.coordinator.available("observe_ui", "readOnly")).toBe(true);
      expect(f.coordinator.available("act_ui", "readOnly")).toBe(false);
      expect(f.coordinator.available("observe_ui", "none")).toBe(false);
      expect(f.coordinator.available("act_ui", "none")).toBe(false);
      expect(f.coordinator.available("observe_ui", "none", true)).toBe(true);
      expect(f.coordinator.available("evaluate_browser", "full")).toBe(false);
    } finally { await f.cleanup(); }
  });

  test("preflight grants with a failed live capture or wrong identity are not ready", async () => {
    const f = fixture();
    try {
      f.runtime.attribution = "caller";
      expect((await f.coordinator.setEnabled(true)).status).toBe("setupRequired");
      f.runtime.attribution = "helper-app";
      f.runtime.command = async () => ({ accessibility: true, screenRecordingPreflight: true,
        screenRecordingCapturable: false, source: { attribution: "helper-app" } });
      expect((await f.coordinator.recheck()).status).toBe("setupRequired");
    } finally { await f.cleanup(); }
  });

  test("disabling cancels a pending approval and prohibits subsequent desktop calls", async () => {
    const f = fixture();
    const controller = new AccessController({ cwd: f.directory, mode: "ask" });
    const approval = deferred();
    controller.subscribe(() => approval.resolve());
    try {
      await f.coordinator.setEnabled(true);
      let executed = false;
      const operation = f.coordinator.run(undefined, async (signal) => {
        await controller.authorizeComputerUse({ toolCallId: "click", toolName: "act_ui", input: {},
          signal, readOnly: false, chatAllowed: false });
        executed = true;
      });
      const rejected = operation.then(() => false, () => true);
      await approval.promise;
      await f.coordinator.setEnabled(false);
      expect(await rejected).toBe(true);
      expect(executed).toBe(false);
      expect(controller.pendingApprovals()).toEqual([]);
      expect(f.coordinator.snapshot()).toMatchObject({ enabled: false, status: "disabled", activeCalls: 0 });
      await expect(f.coordinator.run(undefined, async () => {})).rejects.toThrow("disabled");
    } finally { await f.cleanup(); }
  });

  test("desktop operations serialize and pending restart runs only when idle", async () => {
    const f = fixture();
    const started = deferred();
    const finish = deferred();
    try {
      await f.coordinator.setEnabled(true);
      const operation = f.coordinator.run(undefined, async () => { started.resolve(); await finish.promise; });
      await started.promise;
      const stops = f.runtime.stops;
      expect((await f.coordinator.recheck()).pendingRestart).toBe(true);
      expect(f.runtime.stops).toBe(stops);
      expect(f.coordinator.available("observe_ui", "full")).toBe(false);
      finish.resolve();
      await operation;
      for (let attempt = 0; attempt < 50 && f.runtime.stops === stops; attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      expect(f.runtime.stops).toBe(stops + 1);
    } finally { finish.resolve(); await f.cleanup(); }
  });

  test("read-only rejects actions, and Chat asks without widening file access", async () => {
    const f = fixture();
    try {
      const controller = new AccessController({ cwd: f.directory, mode: "readOnly" });
      await controller.authorizeComputerUse({ toolCallId: "look", toolName: "observe_ui", input: {},
        readOnly: true, chatAllowed: false });
      await expect(controller.authorizeComputerUse({ toolCallId: "click", toolName: "act_ui", input: {},
        readOnly: false, chatAllowed: false })).rejects.toThrow("read-only");
      controller.setMode("none");
      controller.subscribe((request) => controller.resolve(request.id, "allowOnce"));
      await controller.authorizeComputerUse({ toolCallId: "chat-look", toolName: "observe_ui", input: {},
        readOnly: true, chatAllowed: true });
      await expect(controller.authorize({ toolCallId: "shell", toolName: "bash", input: {} })).rejects.toThrow("unavailable");
    } finally { await f.cleanup(); }
  });
});
