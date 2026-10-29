import { randomUUID } from "node:crypto";
import { realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import {
  createBashToolDefinition,
  createEditToolDefinition,
  createFindToolDefinition,
  createGrepToolDefinition,
  createLsToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";

export type AccessMode = "none" | "readOnly" | "ask" | "full";
export type AccessApprovalDecision = "allowOnce" | "deny";

export type AccessApprovalRequest = {
  id: string;
  toolCallId: string;
  toolName: string;
  summary: string;
};

export class AccessPolicyError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "AccessPolicyError";
  }
}

type ToolAuthorizationRequest = {
  toolCallId: string;
  toolName: string;
  input: Record<string, unknown>;
  signal?: AbortSignal;
};

type PendingApproval = {
  request: AccessApprovalRequest;
  resolve: () => void;
  reject: (error: AccessPolicyError) => void;
  removeAbortListener: () => void;
};

const readOnlyTools = new Set(["read", "grep", "find", "ls"]);
export const policyToolNames = ["read", "bash", "edit", "write", "grep", "find", "ls"];

export function activeToolsForMode(mode: AccessMode): string[] {
  switch (mode) {
    case "none":
      return [];
    case "readOnly":
      return ["read", "grep", "find", "ls"];
    case "ask":
    case "full":
      return ["read", "bash", "edit", "write"];
  }
}

export function createPolicyControlledTools(
  cwd: string,
  controller: AccessController,
): ToolDefinition[] {
  const definitions: ToolDefinition<any, any, any>[] = [
    createReadToolDefinition(cwd),
    createBashToolDefinition(cwd),
    createEditToolDefinition(cwd),
    createWriteToolDefinition(cwd),
    createGrepToolDefinition(cwd),
    createFindToolDefinition(cwd),
    createLsToolDefinition(cwd),
  ];
  return definitions.map((definition) => ({
    ...definition,
    execute: async (toolCallId, params, signal, onUpdate, context) => {
      await controller.authorize({
        toolCallId,
        toolName: definition.name,
        input: params as Record<string, unknown>,
        signal,
      });
      return definition.execute(toolCallId, params, signal, onUpdate, context);
    },
  }));
}

export class AccessController {
  mode: AccessMode;
  private readonly cwd: string;
  private readonly canonicalRoot: Promise<string>;
  private readonly makeRequestId: () => string;
  private readonly listeners = new Set<(request: AccessApprovalRequest) => void>();
  private readonly pending = new Map<string, PendingApproval>();

  constructor(options: {
    cwd: string;
    mode: AccessMode;
    makeRequestId?: () => string;
  }) {
    this.mode = options.mode;
    this.cwd = resolve(options.cwd);
    this.canonicalRoot = realpath(this.cwd).catch(() => this.cwd);
    this.makeRequestId = options.makeRequestId ?? randomUUID;
  }

  subscribe(listener: (request: AccessApprovalRequest) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async authorize(request: ToolAuthorizationRequest): Promise<void> {
    if (request.signal?.aborted) {
      throw new AccessPolicyError("approval_cancelled", `Approval cancelled for ${request.toolName}`);
    }
    if (this.mode === "full") return;
    if (this.mode === "none") {
      throw new AccessPolicyError("access_denied", `${request.toolName} is unavailable`);
    }
    if (this.mode === "readOnly") {
      if (!readOnlyTools.has(request.toolName)) {
        throw new AccessPolicyError(
          "access_denied",
          `${request.toolName} is unavailable in read-only mode`,
        );
      }
      await this.assertProjectPath(request);
      return;
    }

    await this.requestApproval(request);
  }

  async authorizeMcp(request: ToolAuthorizationRequest & {
    approvedReadOnly: boolean;
    chatAllowed: boolean;
  }): Promise<void> {
    if (request.signal?.aborted) throw new AccessPolicyError("approval_cancelled", "MCP call cancelled");
    if (this.mode === "full") return;
    if (this.mode === "readOnly") {
      if (request.approvedReadOnly) return;
      throw new AccessPolicyError("access_denied", "This MCP tool has not been approved for read-only access");
    }
    if (this.mode === "none" && !request.chatAllowed) {
      throw new AccessPolicyError("access_denied", "This MCP tool is unavailable in Chat");
    }
    await this.requestApproval(request);
  }

  pendingApprovals(): AccessApprovalRequest[] {
    return Array.from(this.pending.values(), ({ request }) => request);
  }

  resolve(requestId: string, decision: AccessApprovalDecision): void {
    const pending = this.pending.get(requestId);
    if (!pending) {
      throw new AccessPolicyError("approval_not_found", `Approval not found: ${requestId}`);
    }
    this.pending.delete(requestId);
    pending.removeAbortListener();
    if (decision === "allowOnce") {
      pending.resolve();
    } else {
      pending.reject(
        new AccessPolicyError("access_denied", `User denied ${pending.request.toolName}`),
      );
    }
  }

  setMode(mode: AccessMode): void {
    this.mode = mode;
    if (mode === "ask") return;

    for (const [requestId, pending] of this.pending) {
      this.pending.delete(requestId);
      pending.removeAbortListener();
      if (mode === "full") {
        pending.resolve();
      } else {
        pending.reject(
          new AccessPolicyError(
            "access_denied",
            `${pending.request.toolName} was cancelled by the access mode change`,
          ),
        );
      }
    }
  }

  cancelAll(): void {
    for (const [requestId, pending] of this.pending) {
      this.pending.delete(requestId);
      pending.removeAbortListener();
      pending.reject(
        new AccessPolicyError("approval_cancelled", `Approval cancelled for ${pending.request.toolName}`),
      );
    }
  }

  private requestApproval(request: ToolAuthorizationRequest): Promise<void> {
    const approval: AccessApprovalRequest = {
      id: this.makeRequestId(),
      toolCallId: request.toolCallId,
      toolName: request.toolName,
      summary: summarizeToolInput(request.toolName, request.input),
    };

    return new Promise<void>((resolveApproval, rejectApproval) => {
      const abort = () => {
        const pending = this.pending.get(approval.id);
        if (!pending) return;
        this.pending.delete(approval.id);
        pending.removeAbortListener();
        rejectApproval(
          new AccessPolicyError("approval_cancelled", `Approval cancelled for ${request.toolName}`),
        );
      };
      request.signal?.addEventListener("abort", abort, { once: true });
      const removeAbortListener = () => request.signal?.removeEventListener("abort", abort);
      this.pending.set(approval.id, {
        request: approval,
        resolve: resolveApproval,
        reject: rejectApproval,
        removeAbortListener,
      });
      for (const listener of this.listeners) listener(approval);
    });
  }

  private async assertProjectPath(request: ToolAuthorizationRequest): Promise<void> {
    const requestedPath = pathFromToolInput(request.toolName, request.input);
    if (requestedPath === undefined) {
      throw new AccessPolicyError(
        "path_required",
        `${request.toolName} requires a project path in read-only mode`,
      );
    }

    const root = await this.canonicalRoot;
    const absolutePath = isAbsolute(requestedPath)
      ? resolve(requestedPath)
      : resolve(this.cwd, requestedPath);
    const canonicalPath = await canonicalizeExistingAncestor(absolutePath);
    const pathRelativeToRoot = relative(root, canonicalPath);
    if (
      pathRelativeToRoot === ""
      || (!pathRelativeToRoot.startsWith(`..${sep}`) && pathRelativeToRoot !== ".." && !isAbsolute(pathRelativeToRoot))
    ) {
      return;
    }
    throw new AccessPolicyError(
      "path_outside_project",
      `${request.toolName} path is outside the project`,
    );
  }
}

function pathFromToolInput(toolName: string, input: Record<string, unknown>): string | undefined {
  if (toolName === "grep" || toolName === "find" || toolName === "ls") {
    return typeof input.path === "string" ? input.path : ".";
  }
  return typeof input.path === "string" ? input.path : undefined;
}

async function canonicalizeExistingAncestor(path: string): Promise<string> {
  let candidate = path;
  const missingComponents: string[] = [];
  while (true) {
    try {
      return join(await realpath(candidate), ...missingComponents.reverse());
    } catch (error) {
      const code = error instanceof Error && "code" in error ? error.code : undefined;
      if (code !== "ENOENT") throw error;
      const parent = dirname(candidate);
      if (parent === candidate) return path;
      missingComponents.push(candidate.slice(parent.length + (parent.endsWith(sep) ? 0 : 1)));
      candidate = parent;
    }
  }
}

function summarizeToolInput(toolName: string, input: Record<string, unknown>): string {
  if (toolName === "bash" && typeof input.command === "string") {
    return truncate(input.command.replaceAll(/\s+/g, " ").trim());
  }
  if (typeof input.path === "string") return truncate(input.path);
  return toolName;
}

function truncate(value: string): string {
  return value.length <= 240 ? value : `${value.slice(0, 237)}...`;
}
