import { spawn } from "node:child_process";
import { constants } from "node:fs";
import { access, chmod, mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createLocalBashOperations, type BashOperations, type BashToolOptions } from "@earendil-works/pi-coding-agent";

const installerURL = "https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh";
const releasesURL = "https://api.github.com/repos/rtk-ai/rtk/releases/latest";

export type RTKGain = { commands: number; input: number; saved: number; pct: number };
export type RTKDay = RTKGain & { date: string };
export type RTKSnapshot = {
  supported: boolean;
  enabled: boolean;
  path: string | null;
  version: string | null;
  latestVersion: string | null;
  gain: RTKGain | null;
  days: RTKDay[];
  statsError: string | null;
  updateError: string | null;
};
type ProcessResult = { code: number; stdout: string; stderr: string };
type ProcessOptions = { cwd?: string; env?: NodeJS.ProcessEnv; timeout?: number; signal?: AbortSignal };
type Run = (command: string, args: string[], options?: ProcessOptions) => Promise<ProcessResult>;
type RTKOptions = {
  candidates?: string[];
  supported?: boolean;
  run?: Run;
  fetchText?: (url: string) => Promise<string>;
  shell?: BashOperations;
};

class RTKRewriteDenied extends Error {}

/** Keep installation/configuration inside PiWork; terminal agent hooks are never edited. */
export class RTKCoordinator {
  private enabled = false;
  private path: string | null = null;
  private version: string | null = null;
  private latestVersion: string | null = null;
  private changing = false;
  private readonly ready: Promise<void>;
  private readonly run: Run;
  private readonly fetchText: (url: string) => Promise<string>;
  private readonly supported: boolean;
  private readonly managedPath: string;

  constructor(private readonly agentDir: string, private readonly options: RTKOptions = {}) {
    this.run = options.run ?? runProcess;
    this.fetchText = options.fetchText ?? fetchText;
    this.supported = options.supported ?? (process.platform === "darwin" && ["arm64", "x64"].includes(process.arch));
    this.managedPath = join(agentDir, "bin", "rtk");
    this.ready = readFile(join(agentDir, "rtk.json"), "utf8").then((text) => {
      const value: unknown = JSON.parse(text);
      if (!isRecord(value) || typeof value.enabled !== "boolean") throw new Error("Invalid RTK settings");
      this.enabled = value.enabled;
    }).catch((error: unknown) => {
      if (!isRecord(error) || error.code !== "ENOENT") throw error;
    });
    // Surface configuration errors through requests without an unhandled startup rejection.
    void this.ready.catch(() => {});
  }

  async snapshot(checkLatest = false): Promise<RTKSnapshot> {
    await this.ready;
    await this.detect();
    let gain: RTKGain | null = null;
    let days: RTKDay[] = [];
    let statsError: string | null = null;
    let updateError: string | null = null;
    if (this.path) {
      try {
        const result = await this.run(this.path, ["gain", "--daily", "--format", "json"], { timeout: 30_000 });
        if (result.code !== 0) throw new Error(result.stderr.trim() || "rtk gain failed");
        ({ gain, days } = parseRTKGain(result.stdout));
      } catch (error) { statsError = message(error); }
    }
    if (checkLatest) {
      try { await this.checkLatest(); }
      catch (error) { updateError = message(error); }
    }
    return { supported: this.supported, enabled: this.enabled, path: this.path, version: this.version,
      latestVersion: this.latestVersion, gain, days, statsError, updateError };
  }

  async action(action: string): Promise<RTKSnapshot> {
    if (!["enable", "disable", "install", "update"].includes(action)) throw new Error("Unknown RTK action");
    if (this.changing) throw new Error("An RTK operation is already running");
    this.changing = true;
    try {
      await this.ready;
      if (action === "install" || action === "update") {
        if (!this.supported) throw new Error("RTK installation is unavailable on this system");
        await this.install();
      }
      if (action === "enable" || action === "install") {
        await this.detect();
        if (!this.path) throw new Error("Install RTK before enabling it");
        await this.save(true);
      } else if (action === "disable") await this.save(false);
      return await this.snapshot();
    } finally { this.changing = false; }
  }

  /** Wrap Pi's own shell backend, retaining streaming, cancellation, timeouts and exit codes. */
  bashOptions(): BashToolOptions {
    const shell = this.options.shell ?? createLocalBashOperations();
    return { operations: { exec: async (command, cwd, options) => {
      const rewritten = await this.rewrite(command, cwd, options.signal);
      options.signal?.throwIfAborted();
      const env = this.path ? { ...(options.env ?? process.env),
        PATH: `${dirname(this.path)}:${options.env?.PATH ?? process.env.PATH ?? "/usr/bin:/bin"}` } : options.env;
      // Never retry the actual command: an error may follow a completed side effect.
      return shell.exec(rewritten, cwd, { ...options, env });
    } } };
  }

  async rewrite(command: string, cwd: string, signal?: AbortSignal): Promise<string> {
    signal?.throwIfAborted();
    try {
      await this.ready;
      if (!this.enabled || process.env.RTK_DISABLED === "1") return command;
      if (!this.path) await this.detect();
      if (!this.path) return command;
      const result = await this.run(this.path, ["rewrite", command], { cwd, signal, timeout: 2_000 });
      if (result.code === 2 && result.stdout.trim()) throw new RTKRewriteDenied(result.stdout.trim());
      // RTK 1.x returns 3 for a rewrite that still needs host authorization.
      // The policy-controlled tool has already authorized the original command.
      if ((result.code === 0 || result.code === 3) && result.stdout.trim()) return result.stdout.trim();
      return command;
    } catch (error) {
      signal?.throwIfAborted();
      if (error instanceof RTKRewriteDenied) throw error;
      return command;
    }
  }

  private async detect(): Promise<void> {
    const candidates = this.options.candidates ?? [this.managedPath, Bun.which("rtk"),
      join(homedir(), ".local/bin/rtk"), join(homedir(), ".cargo/bin/rtk"), "/opt/homebrew/bin/rtk", "/usr/local/bin/rtk"];
    for (const path of new Set(candidates.filter((path): path is string => Boolean(path)))) {
      try {
        await access(path, constants.X_OK);
        const result = await this.run(path, ["--version"], { timeout: 2_000 });
        const version = parseVersion(result.stdout);
        if (result.code === 0 && version && (Number(version.split(".")[0]) > 0 || Number(version.split(".")[1]) >= 23)) {
          this.path = path;
          this.version = version;
          return;
        }
      } catch { /* Try the next executable, including GUI launches without a shell PATH. */ }
    }
    this.path = this.version = null;
  }

  private async save(enabled: boolean): Promise<void> {
    await mkdir(this.agentDir, { recursive: true, mode: 0o700 });
    const file = join(this.agentDir, "rtk.json");
    await writeFile(file + ".tmp", JSON.stringify({ enabled }) + "\n", { mode: 0o600 });
    await rename(file + ".tmp", file);
    this.enabled = enabled;
  }

  private async checkLatest(): Promise<string> {
    const release: unknown = JSON.parse(await this.fetchText(releasesURL));
    const version = isRecord(release) && typeof release.tag_name === "string" ? parseVersion(release.tag_name) : null;
    if (!version) throw new Error("Could not read the latest RTK release");
    this.latestVersion = version;
    return version;
  }

  private async install(): Promise<void> {
    const version = await this.checkLatest();
    // Use RTK's installer (including its SHA-256 checks) in a staging directory.
    // Only a verified, runnable binary replaces the app-managed installation.
    await mkdir(dirname(this.managedPath), { recursive: true, mode: 0o700 });
    const staging = await mkdtemp(join(dirname(this.managedPath), ".rtk-"));
    try {
      const script = join(staging, "install.sh");
      await writeFile(script, await this.fetchText(installerURL), { mode: 0o600 });
      const result = await this.run("/bin/sh", [script], { timeout: 180_000, env: { ...process.env,
        PATH: "/usr/bin:/bin:/usr/sbin:/sbin", RTK_INSTALL_DIR: staging, RTK_VERSION: `v${version}`, RTK_SKIP_CHECKSUM: "0" } });
      if (result.code !== 0) throw new Error(result.stderr.trim() || result.stdout.trim() || "RTK installation failed");
      const binary = join(staging, "rtk");
      await chmod(binary, 0o755);
      const probe = await this.run(binary, ["--version"], { timeout: 2_000 });
      if (probe.code !== 0 || parseVersion(probe.stdout) !== version) throw new Error("RTK installation verification failed");
      await rename(binary, this.managedPath);
      this.path = this.managedPath;
      this.version = version;
    } finally { await rm(staging, { recursive: true, force: true }); }
  }
}

export function parseRTKGain(output: string): { gain: RTKGain; days: RTKDay[] } {
  const first = output.indexOf("{");
  const last = output.lastIndexOf("}");
  const value: unknown = JSON.parse(output.slice(first, last + 1));
  if (!isRecord(value) || !isRecord(value.summary) || !Array.isArray(value.daily)) throw new Error("RTK returned unreadable statistics");
  const number = (value: unknown): number => {
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw new Error("RTK returned invalid statistics");
    return value;
  };
  const summary = value.summary;
  const gain = { commands: number(summary.total_commands), input: number(summary.total_input),
    saved: number(summary.total_saved), pct: number(summary.avg_savings_pct) };
  const days = value.daily.map((day: unknown): RTKDay => {
    if (!isRecord(day) || typeof day.date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(day.date)) throw new Error("RTK returned an invalid daily record");
    return { date: day.date, commands: number(day.commands), input: number(day.input_tokens),
      saved: number(day.saved_tokens), pct: number(day.savings_pct) };
  }).sort((a, b) => a.date.localeCompare(b.date));
  return { gain, days };
}

function parseVersion(value: string): string | null { return value.match(/(?:^|[^\w.])v?(\d+\.\d+\.\d+(?:-[\w.-]+)?)\b/)?.[1] ?? null; }
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function message(error: unknown): string { return error instanceof Error ? error.message : String(error); }

async function fetchText(url: string): Promise<string> {
  const response = await fetch(url, { signal: AbortSignal.timeout(30_000), headers: { "User-Agent": "pi-work", Accept: "application/vnd.github+json" } });
  if (!response.ok) throw new Error(`RTK download failed (HTTP ${response.status})`);
  const text = await response.text();
  if (text.length > 1_048_576) throw new Error("RTK response exceeded the size limit");
  return text;
}

async function runProcess(command: string, args: string[], options: ProcessOptions = {}): Promise<ProcessResult> {
  options.signal?.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: options.cwd ?? tmpdir(), env: options.env ?? process.env,
      detached: true, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let failure: Error | undefined;
    const stop = (error: Error) => {
      failure = error;
      if (child.pid) { try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); } }
    };
    const abort = () => stop(new Error("RTK operation cancelled"));
    const timer = setTimeout(() => stop(new Error("RTK operation timed out")), options.timeout ?? 30_000);
    child.stdout.on("data", (data: Buffer) => { stdout += data.toString(); if (stdout.length > 8_388_608) stop(new Error("RTK output exceeded the size limit")); });
    child.stderr.on("data", (data: Buffer) => { stderr += data.toString(); if (stderr.length > 1_048_576) stop(new Error("RTK error output exceeded the size limit")); });
    const cleanup = () => { clearTimeout(timer); options.signal?.removeEventListener("abort", abort); };
    child.on("error", (error) => { cleanup(); reject(error); });
    child.on("close", (code) => { cleanup(); if (failure) reject(failure); else resolve({ code: code ?? 1, stdout, stderr }); });
    options.signal?.addEventListener("abort", abort, { once: true });
    if (options.signal?.aborted) abort();
  });
}
