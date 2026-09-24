import { SessionManager } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { unlink } from "node:fs/promises";

export type SessionSummary = {
  id: string;
  path: string;
  cwd: string;
  title: string;
  firstMessage: string;
  messageCount: number;
  createdAt: string;
  modifiedAt: string;
};

export type SessionDraft = {
  manager: SessionManager;
  summary: SessionSummary;
};

export class SessionCatalog {
  async list(cwd?: string, sessionDirectory?: string): Promise<SessionSummary[]> {
    const sessions = cwd
      ? await SessionManager.list(cwd, sessionDirectory)
      : await SessionManager.listAll(sessionDirectory);

    return sessions.map((session) => ({
      id: session.id,
      path: session.path,
      cwd: session.cwd,
      title: session.name?.trim() || session.firstMessage.trim() || "New Session",
      firstMessage: session.firstMessage,
      messageCount: session.messageCount,
      createdAt: session.created.toISOString(),
      modifiedAt: session.modified.toISOString(),
    }));
  }

  createDraft(cwd: string, sessionDirectory?: string): SessionDraft {
    const manager = SessionManager.create(cwd, sessionDirectory);
    const path = manager.getSessionFile();
    if (!path) {
      throw new Error("Pi did not allocate a session file for a persistent draft");
    }

    const createdAt = new Date().toISOString();
    return {
      manager,
      summary: {
        id: manager.getSessionId(),
        path,
        cwd: manager.getCwd(),
        title: "New Session",
        firstMessage: "",
        messageCount: 0,
        createdAt,
        modifiedAt: createdAt,
      },
    };
  }

  open(path: string, sessionDirectory?: string): SessionManager {
    return SessionManager.open(path, sessionDirectory);
  }

  async delete(
    sessionId: string,
    cwd: string,
    sessionDirectory?: string,
    openSession?: Pick<SessionSummary, "id" | "path" | "cwd">,
  ): Promise<void> {
    const session = openSession
      ?? (await this.list(cwd, sessionDirectory)).find((candidate) => candidate.id === sessionId);
    if (!session || session.id !== sessionId || session.cwd !== cwd) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    if (!existsSync(session.path)) return;

    const trashArguments = session.path.startsWith("-") ? ["--", session.path] : [session.path];
    const trashResult = spawnSync("trash", trashArguments, { encoding: "utf-8" });
    if (trashResult.status === 0 || !existsSync(session.path)) return;

    await unlink(session.path);
  }
}
