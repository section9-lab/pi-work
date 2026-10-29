import { afterEach, describe, expect, test } from "bun:test";
import { access, chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AccessController, createPolicyControlledTools } from "../src/access-policy.ts";
import { RTKCoordinator, parseRTKGain } from "../src/rtk.ts";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });
const stats = { summary: { total_commands: 2, total_input: 1000, total_saved: 600, avg_savings_pct: 60 },
  daily: [{ date: "2026-10-29", commands: 1, input_tokens: 400, saved_tokens: 200, savings_pct: 50 },
    { date: "2026-10-28", commands: 1, input_tokens: 600, saved_tokens: 400, savings_pct: 66.7 }] };

async function fixture(enabled = false) {
  const root = await mkdtemp(join(tmpdir(), "pi-work-rtk-"));
  roots.push(root);
  const path = join(root, "rtk");
  await writeFile(path, "#!/bin/sh\nexit 0\n");
  await chmod(path, 0o755);
  await writeFile(join(root, "rtk.json"), JSON.stringify({ enabled }));
  return { root, path };
}

describe("RTK statistics", () => {
  test("reads RTK's schema, tolerates stdout notices, and sorts days", () => {
    const result = parseRTKGain("Notice\n" + JSON.stringify(stats) + "\n");
    expect(result.gain).toEqual({ commands: 2, input: 1000, saved: 600, pct: 60 });
    expect(result.days.map((day) => day.date)).toEqual(["2026-10-28", "2026-10-29"]);
  });
  test("distinguishes a real zero from unreadable or invalid statistics", () => {
    expect(parseRTKGain(JSON.stringify({ summary: { total_commands: 0, total_input: 0,
      total_saved: 0, avg_savings_pct: 0 }, daily: [] })).gain.commands).toBe(0);
    for (const value of ["", "not JSON", "{}", JSON.stringify({ ...stats, summary: {} }),
      JSON.stringify({ ...stats, daily: [{ date: "wrong" }] })]) {
      expect(() => parseRTKGain(value)).toThrow();
    }
  });
});

describe("RTK integration", () => {
  test("is opt-in, persists enable/disable, and takes effect on the same shell tool", async () => {
    const { root, path } = await fixture();
    const executions: string[] = [];
    const coordinator = new RTKCoordinator(root, { candidates: [path],
      run: async (_cmd, args) => ({ code: args[0] === "rewrite" ? 3 : 0,
        stdout: args[0] === "--version" ? "rtk 1.1.0" : args[0] === "gain" ? JSON.stringify(stats) : "rtk git status", stderr: "" }),
      shell: { exec: async (command) => { executions.push(command); return { exitCode: 7 }; } } });
    const exec = coordinator.bashOptions().operations!.exec;
    const options = { onData: () => {} };
    await exec("git status", root, options);
    await coordinator.action("enable");
    expect(await exec("git status", root, options)).toEqual({ exitCode: 7 });
    expect(JSON.parse(await readFile(join(root, "rtk.json"), "utf8"))).toEqual({ enabled: true });
    await coordinator.action("disable");
    await exec("git status", root, options);
    expect(executions).toEqual(["git status", "rtk git status", "git status"]);
  });

  test("unsupported commands and missing/broken RTK pass through without executing twice", async () => {
    const { root, path } = await fixture(true);
    for (const result of [{ code: 1, stdout: "", stderr: "" }, { code: 0, stdout: "", stderr: "" },
      new Error("rewrite timed out")]) {
      const coordinator = new RTKCoordinator(root, { candidates: [path], run: async (_cmd, args) => {
        if (args[0] === "--version") return { code: 0, stdout: "rtk 1.1.0", stderr: "" };
        if (result instanceof Error) throw result;
        return result;
      } });
      expect(await coordinator.rewrite("echo untouched", root)).toBe("echo untouched");
    }
    const missing = new RTKCoordinator(root, { candidates: [join(root, "missing")] });
    expect(await missing.rewrite("git status", root)).toBe("git status");
  });

  test("keeps stats failures visible without preventing enable/disable", async () => {
    const { root, path } = await fixture();
    const coordinator = new RTKCoordinator(root, { candidates: [path], run: async (_cmd, args) => ({
      code: args[0] === "gain" ? 1 : 0, stdout: "rtk 1.1.0", stderr: "database unavailable" }) });
    const state = await coordinator.action("enable");
    expect(state.enabled).toBe(true);
    expect(state.gain).toBeNull();
    expect(state.statsError).toBe("database unavailable");
  });

  test("an RTK pipeline denial with a message stops execution", async () => {
    const { root, path } = await fixture(true);
    const coordinator = new RTKCoordinator(root, { candidates: [path], run: async (_cmd, args) =>
      args[0] === "--version" ? { code: 0, stdout: "rtk 1.1.0", stderr: "" }
        : { code: 2, stdout: "Denied by RTK pipeline", stderr: "" } });
    await expect(coordinator.rewrite("git push", root)).rejects.toThrow("Denied by RTK pipeline");
  });

  test("read-only and denied approvals never invoke RTK or the shell", async () => {
    const { root } = await fixture();
    let executed = false;
    for (const mode of ["readOnly", "ask"] as const) {
      const controller = new AccessController({ cwd: root, mode });
      controller.subscribe((request) => controller.resolve(request.id, "deny"));
      const tool = createPolicyControlledTools(root, controller, { operations: {
        exec: async () => { executed = true; return { exitCode: 0 }; },
      } }).find((tool) => tool.name === "bash")!;
      await expect(tool.execute("call", { command: "git status" }, undefined, undefined, {} as never)).rejects.toThrow();
    }
    expect(executed).toBe(false);
  });

  test("preserves cancellation and does not execute a cancelled command", async () => {
    const { root, path } = await fixture(true);
    const abort = new AbortController();
    let executed = false;
    const coordinator = new RTKCoordinator(root, { candidates: [path], run: async (_cmd, args) => {
      if (args[0] === "rewrite") { abort.abort(); throw new Error("cancelled"); }
      return { code: 0, stdout: "rtk 1.1.0", stderr: "" };
    }, shell: { exec: async () => { executed = true; return { exitCode: 0 }; } } });
    await expect(coordinator.bashOptions().operations!.exec("git status", root,
      { onData: () => {}, signal: abort.signal })).rejects.toThrow();
    expect(executed).toBe(false);
  });

  test("installs with the official installer into staging, verifies, and atomically replaces", async () => {
    const { root } = await fixture();
    const managed = join(root, "bin/rtk");
    const coordinator = new RTKCoordinator(root, { supported: true, candidates: [managed],
      fetchText: async (url) => url.includes("api.github.com") ? '{"tag_name":"v1.1.0"}' : "official installer",
      run: async (cmd, args, options) => {
        if (cmd === "/bin/sh") {
          expect(options?.env?.RTK_SKIP_CHECKSUM).toBe("0");
          expect(options?.env?.RTK_VERSION).toBe("v1.1.0");
          await writeFile(join(options!.env!.RTK_INSTALL_DIR!, "rtk"), "#!/bin/sh\nexit 0\n");
        }
        return { code: 0, stdout: args[0] === "gain" ? JSON.stringify(stats) : "rtk 1.1.0", stderr: "" };
      } });
    const result = await coordinator.action("install");
    expect(result).toMatchObject({ enabled: true, path: managed, version: "1.1.0" });
    await access(managed);
    expect(JSON.parse(await readFile(join(root, "rtk.json"), "utf8"))).toEqual({ enabled: true });
  });

  test("failed installation preserves the existing binary and preference", async () => {
    const { root } = await fixture(true);
    await mkdir(join(root, "bin"));
    const managed = join(root, "bin/rtk");
    await writeFile(managed, "old binary");
    const coordinator = new RTKCoordinator(root, { supported: true, candidates: [managed],
      fetchText: async () => '{"tag_name":"v1.1.0"}',
      run: async () => ({ code: 1, stdout: "", stderr: "checksum mismatch" }) });
    await expect(coordinator.action("update")).rejects.toThrow("checksum mismatch");
    expect(await readFile(managed, "utf8")).toBe("old binary");
    expect(JSON.parse(await readFile(join(root, "rtk.json"), "utf8"))).toEqual({ enabled: true });
  });
});
