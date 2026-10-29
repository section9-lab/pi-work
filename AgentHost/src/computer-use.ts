import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { chmod, cp, mkdir, readFile, rename, rm } from "node:fs/promises";
import { release, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionFactory, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { AccessController, AccessMode } from "./access-policy.ts";

export const computerUseToolNames = new Set([
  "find_roots", "observe_ui", "search_ui", "expand_ui", "inspect_ui", "act_ui", "read_text", "wait_for",
]);
export const computerUseReadTools = new Set([...computerUseToolNames].filter((name) => name !== "act_ui"));

export type ComputerUsePermissions = {
  accessibility: boolean;
  screenRecording: boolean;
  screenRecordingPreflight: boolean;
  attribution: "helper-app" | "caller" | "unknown";
};
export type ComputerUseSnapshot = {
  supported: boolean;
  enabled: boolean;
  status: "unsupported" | "disabled" | "setupRequired" | "ready" | "error" | "restarting";
  permissions: ComputerUsePermissions;
  helperPath: string;
  activeCalls: number;
  pendingRestart: boolean;
  generation: number;
  error?: string;
};

type Upstream = {
  extension: typeof import("@injaneity/pi-computer-use/extensions/computer-use.ts").default;
  bridge: typeof import("@injaneity/pi-computer-use/src/bridge.ts");
  helper: typeof import("@injaneity/pi-computer-use/src/platform/macos/helper.ts").macosHelper;
};
export interface ComputerUseRuntime {
  prepare(): Promise<void>;
  start(): Promise<void>;
  command(name: string, args?: Record<string, unknown>): Promise<Record<string, unknown>>;
  stop(): Promise<void>;
}

const emptyPermissions = (): ComputerUsePermissions => ({
  accessibility: false, screenRecording: false, screenRecordingPreflight: false, attribution: "unknown",
});

/** One host owns one helper and serializes desktop calls across all its sessions. */
export class ComputerUseCoordinator {
  readonly supported: boolean;
  readonly helperPath: string;
  private enabled = false;
  private status: ComputerUseSnapshot["status"] = "disabled";
  private permissions = emptyPermissions();
  private error?: string;
  private readonly settingsPath: string;
  private readonly runtime: ComputerUseRuntime;
  private upstream?: Promise<Upstream>;
  private tail: Promise<unknown> = Promise.resolve();
  private readonly calls = new Set<AbortController>();
  private pendingRestart = false;
  private generation = 0;
  private restoredSession?: string;
  private readonly stateOwners = new Map<string, { session: string; generation: number; target: Record<string, unknown> }>();
  private listeners = new Set<() => void>();

  constructor(agentDir: string, options: { supported?: boolean; runtime?: ComputerUseRuntime } = {}) {
    this.supported = options.supported ?? (process.platform === "darwin" && Number(release().split(".")[0]) >= 23);
    this.helperPath = join(agentDir, "computer-use", "pi-computer-use.app");
    this.settingsPath = join(agentDir, "computer-use.json");
    try {
      if (existsSync(this.settingsPath)) this.enabled = JSON.parse(readFileSync(this.settingsPath, "utf8")).enabled === true;
    } catch { this.error = "Computer use settings could not be read. Computer use remains disabled."; }
    this.status = !this.supported ? "unsupported" : this.enabled ? "setupRequired" : "disabled";
    // Stable across host recovery: reconnect to our existing helper rather than
    // leaving a new LaunchServices daemon behind after every host crash.
    const identity = createHash("sha256").update(agentDir).digest("hex").slice(0, 12);
    const socketDirectory = join(tmpdir(), `pwc-${identity}`);
    if (!options.runtime) {
      process.env.PI_COMPUTER_USE_HELPER_APP_PATH = this.helperPath;
      process.env.PI_CU_SOCKET_PATH = join(socketDirectory, "bridge.sock");
      // Desktop-only first release: never attach to an inherited CDP endpoint.
      delete process.env.PI_COMPUTER_USE_CDP_PORT;
    }
    this.runtime = options.runtime ?? new NativeComputerUseRuntime(this.helperPath, socketDirectory, () => this.loadUpstream());
  }

  snapshot(): ComputerUseSnapshot {
    return { supported: this.supported, enabled: this.enabled, status: this.status,
      permissions: { ...this.permissions }, helperPath: this.helperPath,
      activeCalls: this.calls.size, pendingRestart: this.pendingRestart, generation: this.generation,
      ...(this.error ? { error: this.error } : {}) };
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }
  private publish(): void { for (const listener of this.listeners) listener(); }
  available(name: string, mode: AccessMode, chatAllowed = false): boolean {
    return this.supported && this.enabled && this.status === "ready" && !this.pendingRestart
      && (mode !== "none" || chatAllowed) && computerUseToolNames.has(name)
      && (mode !== "readOnly" || computerUseReadTools.has(name));
  }

  async setEnabled(value: boolean): Promise<ComputerUseSnapshot> {
    if (value && !this.supported) throw new Error("Computer use requires macOS 14 or later.");
    mkdirSync(dirname(this.settingsPath), { recursive: true, mode: 0o700 });
    const temporary = this.settingsPath + ".tmp";
    writeFileSync(temporary, JSON.stringify({ enabled: value }) + "\n", { mode: 0o600 });
    renameSync(temporary, this.settingsPath);
    this.enabled = value;
    this.error = undefined;
    if (!value) {
      this.pendingRestart = false;
      this.status = this.supported ? "disabled" : "unsupported";
      this.cancelCalls();
      this.publish();
      // Do not kill a helper while an already delivered action may be finishing.
      await this.enqueue(async () => { await this.clearRuntime(); await this.runtime.stop(); });
      return this.snapshot();
    }
    this.status = "setupRequired";
    this.publish();
    return this.check();
  }

  async check(): Promise<ComputerUseSnapshot> {
    if (!this.supported || !this.enabled) return this.snapshot();
    if (this.calls.size > 0 || this.pendingRestart) return this.snapshot();
    return this.enqueue(async () => {
      if (!this.enabled) return this.snapshot();
      try {
        await this.runtime.prepare();
        await this.runtime.start();
        const result = await this.runtime.command("checkPermissions");
        const source = record(result.source);
        this.permissions = {
          accessibility: result.accessibility === true,
          screenRecording: result.screenRecordingCapturable === true,
          screenRecordingPreflight: result.screenRecordingPreflight === true,
          attribution: source.attribution === "helper-app" ? "helper-app" : source.attribution === "caller" ? "caller" : "unknown",
        };
        this.status = this.permissions.accessibility && this.permissions.screenRecording
          && this.permissions.attribution === "helper-app" ? "ready" : "setupRequired";
        this.error = undefined;
      } catch (error) { this.status = "error"; this.error = errorMessage(error); }
      if (!this.enabled) this.status = "disabled";
      this.publish();
      return this.snapshot();
    });
  }

  async permission(kind: "accessibility" | "screenRecording"): Promise<ComputerUseSnapshot> {
    this.assertEnabled();
    await this.check();
    return this.enqueue(async () => {
      this.assertEnabled();
      await this.runtime.command("registerPermissions");
      await this.runtime.command("openPermissionPane", { kind });
      return this.snapshot();
    });
  }

  async recheck(force = false): Promise<ComputerUseSnapshot> {
    this.assertEnabled();
    if (this.calls.size > 0 && !force) {
      this.pendingRestart = true;
      this.publish();
      return this.snapshot();
    }
    if (force) this.cancelCalls();
    this.pendingRestart = false;
    this.status = "restarting";
    this.publish();
    await this.enqueue(async () => {
      await this.clearRuntime();
      await this.runtime.stop();
      this.permissions = emptyPermissions();
    });
    return this.check();
  }

  stop(): ComputerUseSnapshot {
    this.pendingRestart = false;
    this.cancelCalls();
    this.generation += 1;
    this.stateOwners.clear();
    this.restoredSession = undefined;
    this.publish();
    return this.snapshot();
  }

  async dispose(): Promise<void> {
    this.cancelCalls();
    await this.enqueue(async () => { await this.clearRuntime(); await this.runtime.stop(); });
  }

  /** The user-initiated test can only touch the parent app's dedicated fixture. */
  async verify(): Promise<{ observed: boolean; acted: boolean; verified: boolean; error?: string }> {
    const result = { observed: false, acted: false, verified: false, error: undefined as string | undefined };
    try {
      await this.run(undefined, async (signal) => {
        const pid = Number(process.env.PI_WORK_APP_PID);
        if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error("The PiWork test window is not available.");
        const upstream = await this.loadUpstream();
        this.generation += 1;
        this.stateOwners.clear();
        const tools = collectTools(upstream.extension);
        // The pinned desktop executors consume cwd/hasUI; restoration also reads
        // the branch. A test has no model, credentials, or conversation history.
        const context = { cwd: dirname(this.settingsPath), hasUI: false,
          sessionManager: { getSessionId: () => "piwork-verification", getBranch: () => [] },
        } as unknown as ExtensionToolContext;
        upstream.bridge.reconstructStateFromBranch(context);
        this.restoredSession = undefined;
        const call = async (name: string, params: Record<string, unknown>) => {
          signal.throwIfAborted();
          this.assertReady();
          const tool = tools.find((candidate) => candidate.name === name);
          if (!tool) throw new Error(`Computer use tool is missing: ${name}`);
          const value = await tool.execute(`verification-${name}`, params, signal, undefined, context);
          if (value.isError) throw new Error("The computer use test tool failed.");
          if (name === "observe_ui" && params.mode === "visual"
              && !value.content.some((part) => part.type === "image" && part.data.length > 0)) {
            throw new Error("The test window outline was returned without a screenshot. Desktop observation did not pass.");
          }
          return record(value.details);
        };
        const found = await call("find_roots", { pid });
        const windows = Array.isArray(found.windows) ? found.windows.map(record) : [];
        const matches = windows.filter((window) => window.pid === pid && window.windowTitle === "PiWork Computer Use Test");
        if (matches.length !== 1 || typeof matches[0]!.windowRef !== "string") throw new Error("Open the PiWork computer use test window and retry.");
        const root = matches[0]!.windowRef;
        const before = await call("observe_ui", { root, mode: "visual" });
        const node = findTestInput(record(before.outline).root);
        const stateId = record(before.capture).stateId;
        if (!node || typeof node.ref !== "string" || typeof stateId !== "string") throw new Error("The test input could not be observed.");
        result.observed = true;
        const text = "PiWork computer use verified";
        await call("act_ui", { stateId, actions: [{ action: "setText", ref: node.ref, text }],
          expect: { ref: node.ref, value: text, timeoutMs: 5_000 } });
        result.acted = true;
        const after = await call("observe_ui", { root, mode: "semantic" });
        const target = record(after.target);
        result.verified = target.pid === pid && target.windowTitle === "PiWork Computer Use Test"
          && findTestInput(record(after.outline).root)?.value === text;
        if (!result.verified) throw new Error("The action returned, but an independent observation did not confirm the text. It was not retried.");
      });
    } catch (error) { result.error = errorMessage(error); }
    return result;
  }

  /** Includes approval and queued calls so disable/restart also cancels pending consent. */
  async run<T>(signal: AbortSignal | undefined, operation: (signal: AbortSignal) => Promise<T>): Promise<T> {
    this.assertReady();
    const call = new AbortController();
    const abort = () => call.abort();
    if (signal?.aborted) call.abort();
    signal?.addEventListener("abort", abort, { once: true });
    this.calls.add(call);
    this.publish();
    try {
      return await this.enqueue(async () => {
        call.signal.throwIfAborted();
        this.assertReady();
        return operation(call.signal);
      });
    } finally {
      signal?.removeEventListener("abort", abort);
      this.calls.delete(call);
      this.publish();
      if (this.pendingRestart && this.calls.size === 0) void this.recheck().catch(() => {});
    }
  }

  extension(controller: AccessController, profile: "chat" | "work"): ExtensionFactory {
    return async (pi) => {
      if (!this.supported) return;
      const upstream = await this.loadUpstream();
      const register = (definition: ToolDefinition) => {
        if (!computerUseToolNames.has(definition.name)) return;
        const readOnly = computerUseReadTools.has(definition.name);
        pi.registerTool({ ...definition, executionMode: "sequential", defaultActive: false,
          annotations: { readOnlyHint: readOnly },
          promptGuidelines: [...(definition.promptGuidelines ?? []),
            "Observe the exact target before acting. After each action observe again and verify the requested result. A delivered action is not proof of success. Never blindly retry an interrupted or ambiguous action."],
          execute: (id, params, signal, onUpdate, context) => this.run(signal, async (callSignal) => {
            const session = context.sessionManager.getSessionId();
            const stateId = record(params).stateId;
            let target: Record<string, unknown> = { root: record(params).root ?? "current desktop", app: record(params).app };
            if (typeof stateId === "string") {
              const owner = this.stateOwners.get(stateId);
              if (!owner || owner.session !== session || owner.generation !== this.generation) {
                throw new Error("Observe the target again. This state belongs to another session or an earlier computer-use service generation.");
              }
              target = owner.target;
            }
            await controller.authorizeComputerUse({ toolCallId: id, toolName: definition.name,
              input: { target, arguments: params }, signal: callSignal, readOnly, chatAllowed: profile === "chat" });
            callSignal.throwIfAborted();
            this.assertReady();
            if (this.restoredSession !== session) {
              upstream.bridge.reconstructStateFromBranch(context);
              this.restoredSession = session;
            }
            // Permission setup belongs to Settings, never to a model tool call.
            const previousHeadless = process.env.PI_COMPUTER_USE_HEADLESS;
            if (controller.mode === "readOnly") process.env.PI_COMPUTER_USE_HEADLESS = "1";
            let result: Awaited<ReturnType<ToolDefinition["execute"]>>;
            try {
              result = await definition.execute(id, params, callSignal, onUpdate, { ...context, hasUI: false });
            } finally {
              if (previousHeadless === undefined) delete process.env.PI_COMPUTER_USE_HEADLESS;
              else process.env.PI_COMPUTER_USE_HEADLESS = previousHeadless;
            }
            callSignal.throwIfAborted();
            const details = record(result.details);
            const successor = record(details.capture).stateId ?? details.stateId;
            if (typeof successor === "string") {
              const observedTarget = record(details.target);
              this.stateOwners.set(successor, { session, generation: this.generation,
                // inspect_ui also has a target, but it is an element rather
                // than a window. Keep the window identity in later approvals.
                target: typeof observedTarget.pid === "number" ? observedTarget : target });
              if (this.stateOwners.size > 128) this.stateOwners.delete(this.stateOwners.keys().next().value!);
            }
            return result;
          }),
        });
      };
      // Keep upstream schemas/executors. Its eager setup and global shutdown
      // hooks belong to this coordinator, not to each individual Pi session.
      for (const definition of collectTools(upstream.extension)) register(definition);
    };
  }

  private loadUpstream(): Promise<Upstream> {
    this.upstream ??= Promise.all([
      import("@injaneity/pi-computer-use/extensions/computer-use.ts"),
      import("@injaneity/pi-computer-use/src/bridge.ts"),
      import("@injaneity/pi-computer-use/src/platform/macos/helper.ts"),
    ]).then(([extension, bridge, helper]) => ({ extension: extension.default, bridge, helper: helper.macosHelper }));
    return this.upstream;
  }
  private assertEnabled(): void {
    if (!this.supported || !this.enabled) throw new Error("Computer use is disabled or unavailable. Open Settings → Computer Use.");
  }
  private assertReady(): void {
    this.assertEnabled();
    if (this.status !== "ready" || this.pendingRestart) throw new Error("Computer use is not ready. Apply permissions in Settings → Computer Use.");
  }
  private cancelCalls(): void { for (const call of this.calls) call.abort(); }
  private async clearRuntime(): Promise<void> {
    this.generation += 1;
    this.stateOwners.clear();
    this.restoredSession = undefined;
    if (this.upstream) await (await this.upstream).bridge.shutdownComputerUseSession();
  }
  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const next = this.tail.then(operation, operation);
    this.tail = next.catch(() => {});
    return next;
  }
}

class NativeComputerUseRuntime implements ComputerUseRuntime {
  constructor(private readonly helperPath: string, private readonly socketDirectory: string,
    private readonly upstream: () => Promise<Upstream>) {}

  async prepare(): Promise<void> {
    const source = process.env.PI_WORK_COMPUTER_USE_BUNDLE_PATH
      ?? join(import.meta.dir, "../node_modules/@injaneity/pi-computer-use/prebuilt/macos/universal/pi-computer-use.app");
    const executable = "Contents/MacOS/bridge";
    const sourceBytes = await readFile(join(source, executable));
    const installed = await readFile(join(this.helperPath, executable)).catch(() => undefined);
    const hash = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");
    if (installed && hash(installed) === hash(sourceBytes)) {
      try { await runProcess("/usr/bin/codesign", ["--verify", "--strict", this.helperPath]); return; }
      catch { /* Repair a damaged Info.plist or resource seal from the trusted payload. */ }
    }
    await runProcess("/usr/bin/codesign", ["--verify", "--strict", source]);
    await this.stop();
    await mkdir(dirname(this.helperPath), { recursive: true, mode: 0o700 });
    const staged = this.helperPath + ".staging";
    await rm(staged, { recursive: true, force: true });
    await cp(source, staged, { recursive: true, preserveTimestamps: true });
    await chmod(join(staged, executable), 0o755);
    await runProcess("/usr/bin/codesign", ["--verify", "--strict", staged]);
    await rm(this.helperPath, { recursive: true, force: true });
    await rename(staged, this.helperPath);
  }
  async start(): Promise<void> {
    await mkdir(this.socketDirectory, { recursive: true, mode: 0o700 });
    await chmod(this.socketDirectory, 0o700);
    const { helper } = await this.upstream();
    // Upstream's 1s daemon ping also runs a live ScreenCaptureKit probe. Before
    // permission is granted that probe can take 5s; use its lower-level client
    // with an explicit management timeout instead of repeatedly launching it.
    const isRunning = async () => {
      if (!existsSync(join(this.socketDirectory, "bridge.sock"))) return false;
      try {
        const diagnostics = await helper.daemonCommand<Record<string, unknown>>("diagnostics", {}, 15_000);
        if (diagnostics.protocolVersion !== 6) throw new Error("Computer control service protocol does not match the pinned 0.5.1 package.");
        return true;
      } catch (error) {
        if (/ENOENT|ECONNREFUSED/.test(errorMessage(error))) return false;
        throw error;
      }
    };
    if (await isRunning()) return;
    await runProcess("/usr/bin/open", ["-n", "-g", this.helperPath, "--args", "serve", "--socket", join(this.socketDirectory, "bridge.sock")]);
    for (let attempt = 0; attempt < 40; attempt += 1) {
      if (await isRunning()) return;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error("The computer control service did not start.");
  }
  async command(name: string, args: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    return (await this.upstream()).helper.daemonCommand<Record<string, unknown>>(name, args, 15_000);
  }
  async stop(): Promise<void> {
    if (!existsSync(join(this.socketDirectory, "bridge.sock"))) return;
    await this.command("shutdown").catch(() => {});
    await new Promise((resolve) => setTimeout(resolve, 400));
    await rm(this.socketDirectory, { recursive: true, force: true });
  }
}

async function runProcess(command: string, args: string[]): Promise<void> {
  const child = Bun.spawn([command, ...args], { stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill(), 15_000);
  try {
    const [code, , error] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    if (code !== 0) throw new Error(error.trim() || `${command} failed (${code})`);
  } finally { clearTimeout(timer); }
}
function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
function errorMessage(error: unknown): string { return error instanceof Error ? error.message : String(error); }

function collectTools(extension: Upstream["extension"]): ToolDefinition[] {
  const tools: ToolDefinition[] = [];
  extension(new Proxy({} as ExtensionAPI, { get: (_target, key) => {
    if (key === "registerTool") return (tool: ToolDefinition) => { tools.push(tool); };
    if (key === "on" || key === "registerCommand") return () => {};
    throw new Error(`Unsupported computer use extension hook: ${String(key)}`);
  } }));
  return tools;
}

function findTestInput(value: unknown): Record<string, unknown> | undefined {
  const node = record(value);
  if (node.identifier === "piwork-computer-use-test-input") return node;
  for (const child of Array.isArray(node.children) ? node.children : []) {
    const found = findTestInput(child);
    if (found) return found;
  }
  return undefined;
}
