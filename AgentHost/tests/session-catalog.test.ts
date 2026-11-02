import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";

import { SessionCatalog } from "../src/session-catalog.ts";

describe("SessionCatalog", () => {
  const temporaryDirectories: string[] = [];

  afterEach(() => {
    for (const directory of temporaryDirectories.splice(0)) {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  test("lists native Pi sessions as stable sidebar summaries", async () => {
    const root = mkdtempSync(join(tmpdir(), "pi-work-host-session-test-"));
    temporaryDirectories.push(root);
    const cwd = join(root, "project");
    const sessionDirectory = join(root, "sessions");
    mkdirSync(cwd, { recursive: true });

    const manager = SessionManager.create(cwd, sessionDirectory, { id: "session-one" });
    manager.appendMessage({
      role: "user",
      content: "Implement project sessions",
      timestamp: Date.now(),
    });
    manager.appendMessage({
      role: "assistant",
      content: [{ type: "text", text: "Done" }],
      api: "openai-completions",
      provider: "openai",
      model: "test-model",
      usage: {
        input: 1,
        output: 1,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 2,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "stop",
      timestamp: Date.now(),
    });
    manager.appendSessionInfo("Session integration");

    const catalog = new SessionCatalog();
    const sessions = await catalog.list(cwd, sessionDirectory);

    expect(sessions).toHaveLength(1);
    expect(sessions[0]).toMatchObject({
      id: "session-one",
      cwd,
      title: "Session integration",
      firstMessage: "Implement project sessions",
      messageCount: 2,
    });
    expect(sessions[0]?.path).toBe(manager.getSessionFile()!);
    expect(await catalog.resolvePath("session-one", "session-one", sessionDirectory))
      .toBe(manager.getSessionFile()!);
  });

  test("preserves explicit paths and rejects unknown opaque IDs", async () => {
    const root = mkdtempSync(join(tmpdir(), "pi-work-export-path-test-"));
    temporaryDirectories.push(root);
    const catalog = new SessionCatalog();
    expect(await catalog.resolvePath("session-one", join(root, "explicit.jsonl"), root))
      .toBe(join(root, "explicit.jsonl"));
    await expect(catalog.resolvePath("missing", "missing", root))
      .rejects.toThrow("Session not found: missing");
  });

  test("creates a native Pi draft without writing empty history", () => {
    const root = mkdtempSync(join(tmpdir(), "pi-work-host-draft-test-"));
    temporaryDirectories.push(root);
    const cwd = join(root, "project");
    const sessionDirectory = join(root, "sessions");
    mkdirSync(cwd, { recursive: true });

    const catalog = new SessionCatalog();
    const draft = catalog.createDraft(cwd, sessionDirectory);

    expect(draft.summary.id).toBe(draft.manager.getSessionId());
    expect(draft.summary.path).toBe(draft.manager.getSessionFile()!);
    expect(draft.summary.cwd).toBe(cwd);
    expect(draft.summary.title).toBe("New Session");
    expect(existsSync(draft.summary.path)).toBe(false);
  });

  test("opens an existing native Pi session", () => {
    const root = mkdtempSync(join(tmpdir(), "pi-work-host-open-test-"));
    temporaryDirectories.push(root);
    const cwd = join(root, "project");
    const sessionDirectory = join(root, "sessions");
    mkdirSync(cwd, { recursive: true });
    const created = SessionManager.create(cwd, sessionDirectory, { id: "session-one" });
    created.appendMessage({
      role: "user",
      content: "Resume this session",
      timestamp: Date.now(),
    });
    created.appendMessage({
      role: "assistant",
      content: [{ type: "text", text: "Ready" }],
      api: "openai-completions",
      provider: "openai",
      model: "test-model",
      usage: {
        input: 1,
        output: 1,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 2,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "stop",
      timestamp: Date.now(),
    });

    const opened = new SessionCatalog().open(created.getSessionFile()!, sessionDirectory);

    expect(opened.getSessionId()).toBe("session-one");
    expect(opened.getCwd()).toBe(cwd);
    expect(opened.getEntries()).toHaveLength(2);
  });
});
