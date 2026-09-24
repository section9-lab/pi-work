import {
  createAgentSession,
  type AgentSession,
  type AgentSessionEvent,
  type CreateAgentSessionOptions,
  type ModelRuntime,
  type SessionManager,
  type SettingsManager,
} from "@earendil-works/pi-coding-agent";
import type { ImageContent } from "@earendil-works/pi-ai";

import {
  AccessController,
  activeToolsForMode,
  createPolicyControlledTools,
  type AccessApprovalDecision,
  type AccessMode,
} from "./access-policy.ts";
import {
  createACPExtensionUIContext,
  type ACPElicitationRequester,
  type ACPExtensionUIContext,
} from "./acp-extension-ui.ts";
import {
  SessionRegistryError,
  type SessionHandle,
  type SessionHandleEvent,
  type SessionHandleSnapshot,
  type SessionContextUsage,
  type SessionMessage,
  type SessionMessageContent,
  type SessionModel,
  type SessionModelOption,
  type SessionModelOptions,
  type SessionModelOptionSelection,
  type SessionExtensionWidget,
  type SessionSlashCommand,
  type SessionThinkingLevel,
  type SessionThinkingState,
  type SessionTranscriptPage,
} from "./session-registry.ts";
import { normalizeModel, supportsFastMode } from "./model-catalog.ts";
import {
  createPiWorkResourceLoader,
  type PiWorkProfile,
} from "./pi-work-context-extension.ts";

type PiAgentSession = Pick<
  AgentSession,
  | "sessionId"
  | "messages"
  | "model"
  | "getContextUsage"
  | "thinkingLevel"
  | "setModel"
  | "setThinkingLevel"
  | "getAvailableThinkingLevels"
  | "getAllTools"
  | "setActiveToolsByName"
  | "extensionRunner"
  | "resourceLoader"
  | "bindExtensions"
  | "prompt"
  | "abort"
  | "reload"
  | "exportToHtml"
  | "dispose"
  | "subscribe"
> & {
  agent: Pick<AgentSession["agent"], "streamFunction">;
  modelRuntime: Pick<ModelRuntime, "getModel">;
};
type CreateSession = (options: CreateAgentSessionOptions) => Promise<{ session: PiAgentSession }>;

type PiModel = NonNullable<AgentSession["model"]>;

const oneMillionContextWindow = 1_050_000;
const gitBranchEntryType = "pi-work.git-branch";
const builtInPiToolNames = ["read", "bash", "edit", "write", "grep", "find", "ls"];
const snapshotToolOutputPreviewBytes = 16 * 1024;

function transcriptPageStart(
  messages: ReadonlyArray<AgentSession["messages"][number]>,
  end: number,
  limit: number,
): number {
  const visibleLimit = Math.max(1, Math.floor(limit));
  let visibleCount = 0;
  let start = end;
  while (start > 0 && visibleCount < visibleLimit) {
    start -= 1;
    const message = messages[start];
    if (message?.role !== "custom" || message.display) {
      visibleCount += 1;
    }
  }
  while (start > 0 && messages[start]?.role === "toolResult") {
    start -= 1;
  }
  return start;
}

function transcriptCursorAnchor(
  message: AgentSession["messages"][number] | undefined,
): string | undefined {
  if (!message) return undefined;
  return JSON.stringify([
    message.role,
    Number.isFinite(message.timestamp) ? message.timestamp : 0,
    "toolCallId" in message ? message.toolCallId : null,
  ]);
}

function encodeTranscriptCursor(
  revision: string,
  end: number,
  messages: ReadonlyArray<AgentSession["messages"][number]>,
): string {
  return Buffer.from(JSON.stringify({
    revision,
    end,
    anchor: transcriptCursorAnchor(messages[end]),
  })).toString("base64url");
}

function selectedGitBranch(sessionManager: SessionManager): string | undefined {
  const entries = sessionManager.getEntries();
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry.type !== "custom" || entry.customType !== gitBranchEntryType) continue;
    const data = entry.data;
    if (!data || typeof data !== "object" || !("branch" in data)) continue;
    const branch = (data as { branch?: unknown }).branch;
    if (typeof branch === "string" && branch.length > 0) return branch;
  }
  return undefined;
}

function oneMillionContextConfiguration(
  model: PiModel | undefined,
): { shortContextWindow: number; longContextWindow: number } | undefined {
  if (!model || model.provider !== "openai" || model.api !== "openai-responses") {
    return undefined;
  }
  const shortContextTier = model.cost.tiers?.find((tier) => (
    tier.inputTokensAbove > 0 && tier.inputTokensAbove < oneMillionContextWindow
  ));
  if (!shortContextTier) return undefined;
  return {
    shortContextWindow: shortContextTier.inputTokensAbove,
    longContextWindow: oneMillionContextWindow,
  };
}

export type SessionProfile = PiWorkProfile;
type ExtensionToolSelection = "none" | "all" | "pi-web-access";

function extensionToolNames(
  session: PiAgentSession,
  selection: ExtensionToolSelection,
): string[] {
  if (selection === "none") return [];
  return session.getAllTools()
    .filter(({ sourceInfo }) => (
      sourceInfo.source !== "builtin"
      && sourceInfo.source !== "sdk"
      && (selection === "all" || sourceInfo.source === "npm:pi-web-access")
    ))
    .map(({ name }) => name);
}

export async function createPiSessionHandle(
  options: {
    sessionManager: SessionManager;
    profile: SessionProfile;
    modelRuntime?: ModelRuntime;
    accessMode?: AccessMode;
    agentDir?: string;
    settingsManager?: SettingsManager;
    now?: () => Date;
    timeZone?: string;
    requestElicitation?: ACPElicitationRequester;
  },
  createSession: CreateSession = createAgentSession,
): Promise<PiSessionHandle> {
  const createOptions: CreateAgentSessionOptions = {
    cwd: options.sessionManager.getCwd(),
    sessionManager: options.sessionManager,
    modelRuntime: options.modelRuntime,
    agentDir: options.agentDir,
    settingsManager: options.settingsManager,
  };
  const accessMode: AccessMode = options.profile === "chat"
    ? "none"
    : (options.accessMode ?? "full");
  const accessController = new AccessController({
    cwd: options.sessionManager.getCwd(),
    mode: accessMode,
  });
  createOptions.resourceLoader = await createPiWorkResourceLoader({
    cwd: options.sessionManager.getCwd(),
    profile: options.profile,
    agentDir: options.agentDir,
    settingsManager: options.settingsManager,
    now: options.now,
    timeZone: options.timeZone,
    selectedGitBranch: () => selectedGitBranch(options.sessionManager),
  });
  if (options.profile === "chat") {
    createOptions.excludeTools = builtInPiToolNames;
  } else {
    createOptions.customTools = [
      ...createPolicyControlledTools(
        options.sessionManager.getCwd(),
        accessController,
      ),
    ];
  }

  const { session } = await createSession(createOptions);
  let handle: PiSessionHandle | undefined;
  const pendingWidgets = new Map<string, SessionExtensionWidget>();
  const pendingStatuses = new Map<string, string>();
  let extensionUI: ACPExtensionUIContext | undefined;
  if (options.requestElicitation) {
    extensionUI = createACPExtensionUIContext(
      session.sessionId,
      options.requestElicitation,
      {
        onWidgetChanged(key, widget) {
          if (handle) handle.setExtensionWidget(key, widget);
          else if (widget === undefined) pendingWidgets.delete(key);
          else pendingWidgets.set(key, widget);
        },
        onStatusChanged(key, text) {
          if (handle) {
            handle.setExtensionStatus(key, text);
          } else if (text === undefined) {
            pendingStatuses.delete(key);
          } else {
            pendingStatuses.set(key, text);
          }
        },
      },
    );
    await session.bindExtensions({
      uiContext: extensionUI,
      mode: "rpc",
    });
  }
  const extensionSelection: ExtensionToolSelection = options.profile === "chat"
    ? "pi-web-access"
    : "all";
  const alwaysActiveToolNames = extensionToolNames(session, extensionSelection);
  session.setActiveToolsByName([
    ...activeToolsForMode(accessMode),
    ...alwaysActiveToolNames,
  ]);
  handle = new PiSessionHandle(
    session,
    options.sessionManager,
    accessController,
    [],
    extensionSelection,
    extensionUI,
  );
  for (const [key, text] of pendingStatuses) handle.setExtensionStatus(key, text);
  for (const [key, widget] of pendingWidgets) handle.setExtensionWidget(key, widget);
  return handle;
}

export class PiSessionHandle implements SessionHandle {
  private fastModeEnabled = false;
  private transcriptRevision = crypto.randomUUID();
  private readonly extensionListeners = new Set<(event: SessionHandleEvent) => void>();
  private readonly extensionWidgets = new Map<string, SessionExtensionWidget>();
  private readonly extensionStatuses = new Map<string, string>();

  constructor(
    private readonly session: PiAgentSession,
    private readonly sessionManager: SessionManager,
    private readonly accessController = new AccessController({
      cwd: sessionManager.getCwd(),
      mode: "full",
    }),
    private readonly alwaysActiveToolNames: readonly string[] = [],
    private readonly extensionToolSelection: ExtensionToolSelection = "none",
    private readonly extensionUI?: ACPExtensionUIContext,
  ) {
    const streamFunction = session.agent.streamFunction;
    session.agent.streamFunction = (model, context, streamOptions) => {
      if (!supportsFastMode(model)) {
        return streamFunction(model, context, streamOptions);
      }
      const options = {
        ...streamOptions,
        serviceTier: this.fastModeEnabled ? "priority" : "default",
      };
      return streamFunction(model, context, options);
    };
  }

  get sessionId(): string {
    return this.session.sessionId;
  }

  descriptor(): SessionHandleSnapshot["session"] {
    const explicitTitle = this.sessionManager.getSessionName()?.trim();
    const firstUserIndex = this.session.messages.findIndex((message) => message.role === "user");
    const firstUserMessage = firstUserIndex < 0
      ? undefined
      : normalizeAgentMessages(
          this.sessionId,
          [this.session.messages[firstUserIndex]!],
          { startIndex: firstUserIndex },
        )[0];
    const firstUserText = firstUserMessage?.content
      .filter((content): content is Extract<SessionMessageContent, { type: "text" }> => (
        content.type === "text"
      ))
      .map((content) => content.text)
      .join(" ")
      .trim();
    return {
      id: this.sessionId,
      path: this.sessionManager.getSessionFile() ?? "",
      cwd: this.sessionManager.getCwd(),
      title: explicitTitle || firstUserText || "New Session",
    };
  }

  snapshot(options: { messageLimit?: number } = {}): SessionHandleSnapshot {
    const messageLimit = options.messageLimit === undefined
      ? this.session.messages.length
      : Math.max(1, Math.floor(options.messageLimit));
    const messageStartIndex = transcriptPageStart(
      this.session.messages,
      this.session.messages.length,
      messageLimit,
    );
    const messages = normalizeAgentMessages(
      this.sessionId,
      this.session.messages.slice(messageStartIndex),
      {
        maxToolOutputBytes: snapshotToolOutputPreviewBytes,
        startIndex: messageStartIndex,
      },
    );
    const contextUsage = this.contextUsage();
    const gitBranch = selectedGitBranch(this.sessionManager);
    return {
      session: this.descriptor(),
      messages,
      ...(options.messageLimit === undefined ? {} : {
        history: {
          revision: this.transcriptRevision,
          nextCursor: messageStartIndex > 0
            ? encodeTranscriptCursor(
                this.transcriptRevision,
                messageStartIndex,
                this.session.messages,
              )
            : null,
          hasMore: messageStartIndex > 0,
        },
      }),
      ...(gitBranch ? { gitBranch } : {}),
      model: this.session.model ? normalizeModel(this.session.model) : null,
      ...(contextUsage ? { contextUsage } : {}),
      thinkingLevel: this.session.thinkingLevel,
      availableThinkingLevels: this.session.getAvailableThinkingLevels(),
      modelOptions: this.modelOptions(),
      accessMode: this.accessController.mode,
      pendingApprovals: this.accessController.pendingApprovals(),
      ...(this.extensionWidgets.size > 0 ? { extensionWidgets: Object.fromEntries(
        [...this.extensionWidgets].map(([key, widget]) => [
          key, { ...widget, lines: [...widget.lines] },
        ]),
      ) } : {}),
      ...(this.extensionStatuses.size > 0
        ? { extensionStatuses: Object.fromEntries(this.extensionStatuses) }
        : {}),
    };
  }

  transcriptPage(cursor: string, limit: number): SessionTranscriptPage {
    let decoded: unknown;
    try {
      decoded = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    } catch {
      throw new SessionRegistryError("invalid_history_cursor", "History cursor is invalid");
    }
    if (
      !decoded
      || typeof decoded !== "object"
      || !("revision" in decoded)
      || decoded.revision !== this.transcriptRevision
    ) {
      throw new SessionRegistryError("stale_history_cursor", "History cursor is stale");
    }
    const end = "end" in decoded ? decoded.end : undefined;
    const anchor = "anchor" in decoded ? decoded.anchor : undefined;
    if (!Number.isSafeInteger(end) || (end as number) <= 0 || (end as number) > this.session.messages.length) {
      throw new SessionRegistryError("invalid_history_cursor", "History cursor is invalid");
    }
    if (
      typeof anchor !== "string"
      || anchor !== transcriptCursorAnchor(this.session.messages[end as number])
    ) {
      throw new SessionRegistryError("stale_history_cursor", "History cursor is stale");
    }

    const pageEndIndex = end as number;
    const pageStartIndex = transcriptPageStart(this.session.messages, pageEndIndex, limit);
    return {
      sessionId: this.sessionId,
      messages: normalizeAgentMessages(
        this.sessionId,
        this.session.messages.slice(pageStartIndex, pageEndIndex),
        {
          maxToolOutputBytes: snapshotToolOutputPreviewBytes,
          startIndex: pageStartIndex,
        },
      ),
      revision: this.transcriptRevision,
      nextCursor: pageStartIndex > 0
        ? encodeTranscriptCursor(
            this.transcriptRevision,
            pageStartIndex,
            this.session.messages,
          )
        : null,
      hasMore: pageStartIndex > 0,
    };
  }

  toolOutput(toolCallId: string): string {
    for (let index = this.session.messages.length - 1; index >= 0; index -= 1) {
      const message = this.session.messages[index];
      if (message.role === "toolResult" && message.toolCallId === toolCallId) {
        return normalizedToolOutput(message.content);
      }
    }
    throw new SessionRegistryError(
      "tool_output_not_found",
      `Tool output not found: ${toolCallId}`,
    );
  }

  exportHtml(outputPath: string): Promise<string> {
    return this.session.exportToHtml(outputPath);
  }

  contextUsage(): SessionContextUsage | undefined {
    const usage = this.session.getContextUsage();
    if (!usage) return undefined;
    return {
      tokens: usage.tokens,
      contextWindow: usage.contextWindow,
      percent: usage.percent,
    };
  }

  commands(): SessionSlashCommand[] {
    const extensions = this.session.extensionRunner.getRegisteredCommands().map((command) => ({
      name: command.invocationName,
      description: command.description,
      source: "extension" as const,
    }));
    const skills = this.session.resourceLoader.getSkills().skills.map((skill) => ({
      name: `skill:${skill.name}`,
      description: skill.description,
      source: "skill" as const,
    }));
    return [...extensions, ...skills];
  }

  rename(title: string): string {
    this.sessionManager.appendSessionInfo(title);
    return title;
  }

  setGitBranch(branch: string): string {
    const selectedBranch = branch.trim();
    if (!selectedBranch) {
      throw new SessionRegistryError("git_branch_invalid", "Git branch cannot be empty");
    }
    if (normalizeAgentMessages(this.sessionId, this.session.messages).length > 0) {
      throw new SessionRegistryError(
        "git_branch_locked",
        "Git branch can only be selected before the conversation starts",
      );
    }
    this.sessionManager.appendCustomEntry(gitBranchEntryType, { branch: selectedBranch });
    return selectedBranch;
  }

  async setModel(provider: string, modelId: string): Promise<SessionModel> {
    const model = this.session.modelRuntime.getModel(provider, modelId);
    if (!model) {
      throw new SessionRegistryError(
        "model_not_found",
        `Model not found: ${provider}/${modelId}`,
      );
    }
    try {
      await this.session.setModel(model);
    } catch (error) {
      throw new SessionRegistryError(
        "model_unavailable",
        error instanceof Error ? error.message : String(error),
      );
    }
    this.fastModeEnabled = false;
    return normalizeModel(model);
  }

  setThinkingLevel(level: SessionThinkingLevel): SessionThinkingState {
    this.session.setThinkingLevel(level);
    return {
      thinkingLevel: this.session.thinkingLevel,
      availableThinkingLevels: this.session.getAvailableThinkingLevels(),
    };
  }

  async setModelOption(
    option: SessionModelOption,
    enabled: boolean,
  ): Promise<SessionModelOptionSelection> {
    if (option === "fastMode") {
      if (!supportsFastMode(this.session.model)) {
        throw new SessionRegistryError(
          "model_option_unsupported",
          "The selected model does not support Fast mode",
        );
      }
      this.fastModeEnabled = enabled;
      return this.modelOptionSelection();
    }

    const configuration = oneMillionContextConfiguration(this.session.model);
    if (!configuration || !this.session.model) {
      throw new SessionRegistryError(
        "model_option_unsupported",
        "The selected model does not support a 1M context window",
      );
    }
    const model: PiModel = {
      ...this.session.model,
      contextWindow: enabled
        ? configuration.longContextWindow
        : configuration.shortContextWindow,
    };
    try {
      await this.session.setModel(model);
    } catch (error) {
      throw new SessionRegistryError(
        "model_unavailable",
        error instanceof Error ? error.message : String(error),
      );
    }
    return this.modelOptionSelection();
  }

  private modelOptions(): SessionModelOptions {
    const model = this.session.model;
    const contextConfiguration = oneMillionContextConfiguration(model);
    return {
      fastMode: {
        supported: supportsFastMode(model),
        enabled: supportsFastMode(model) && this.fastModeEnabled,
      },
      oneMillionContext: {
        supported: contextConfiguration !== undefined,
        enabled: contextConfiguration !== undefined
          && (model?.contextWindow ?? 0) >= contextConfiguration.longContextWindow,
      },
    };
  }

  private modelOptionSelection(): SessionModelOptionSelection {
    const model = this.session.model;
    if (!model) {
      throw new SessionRegistryError("model_unavailable", "No model is selected");
    }
    const contextUsage = this.contextUsage();
    return {
      model: normalizeModel(model),
      ...(contextUsage ? { contextUsage } : {}),
      modelOptions: this.modelOptions(),
    };
  }

  setAccessMode(mode: AccessMode): AccessMode {
    this.accessController.setMode(mode);
    this.refreshActiveTools();
    return mode;
  }

  resolveApproval(requestId: string, decision: AccessApprovalDecision): void {
    this.accessController.resolve(requestId, decision);
  }

  async prompt(text: string, images: ImageContent[] = []): Promise<void> {
    await this.session.prompt(text, images.length > 0 ? { images } : undefined);
    const lastMessage = this.session.messages.at(-1);
    if (lastMessage?.role === "assistant" && lastMessage.stopReason === "error") {
      throw new Error(lastMessage.errorMessage || "Model request failed");
    }
  }

  abort(): Promise<void> {
    this.accessController.cancelAll();
    return this.session.abort();
  }

  async reload(): Promise<void> {
    await this.session.reload({
      beforeSessionStart: async () => {
        this.extensionUI?.clearWidgets();
        for (const key of this.extensionStatuses.keys()) this.setExtensionStatus(key, undefined);
        for (const key of this.extensionWidgets.keys()) this.setExtensionWidget(key, undefined);
      },
    });
    this.transcriptRevision = crypto.randomUUID();
    this.refreshActiveTools();
  }

  dispose(): void {
    this.accessController.cancelAll();
    this.extensionUI?.clearWidgets();
    this.session.dispose();
  }

  subscribe(listener: (event: SessionHandleEvent) => void): () => void {
    const unsubscribeSession = this.session.subscribe((event) => {
      const normalized = normalizeAgentSessionEvent(event);
      if (normalized) listener(normalized);
    });
    const unsubscribeApprovals = this.accessController.subscribe((approval) => {
      listener({ type: "approvalRequested", approval });
    });
    this.extensionListeners.add(listener);
    for (const [key, text] of this.extensionStatuses) {
      listener({ type: "extensionStatusChanged", key, text });
    }
    for (const [key, widget] of this.extensionWidgets) {
      listener({ type: "extensionWidgetChanged", key, widget });
    }
    return () => {
      unsubscribeSession();
      unsubscribeApprovals();
      this.extensionListeners.delete(listener);
    };
  }

  setExtensionWidget(key: string, widget: SessionExtensionWidget | undefined): void {
    if (widget === undefined) this.extensionWidgets.delete(key);
    else this.extensionWidgets.set(key, { ...widget, lines: [...widget.lines] });
    for (const listener of this.extensionListeners) {
      listener({ type: "extensionWidgetChanged", key, ...(widget === undefined ? {} : { widget }) });
    }
  }

  setExtensionStatus(key: string, text: string | undefined): void {
    if (text === undefined) this.extensionStatuses.delete(key);
    else this.extensionStatuses.set(key, text);
    for (const listener of this.extensionListeners) {
      listener({ type: "extensionStatusChanged", key, ...(text === undefined ? {} : { text }) });
    }
  }

  private refreshActiveTools(): void {
    const refreshedExtensionToolNames = extensionToolNames(
      this.session,
      this.extensionToolSelection,
    );
    this.session.setActiveToolsByName([
      ...activeToolsForMode(this.accessController.mode),
      ...this.alwaysActiveToolNames,
      ...refreshedExtensionToolNames,
    ]);
  }
}

export function normalizeAgentMessages(
  sessionId: string,
  messages: ReadonlyArray<AgentSession["messages"][number]>,
  options: { maxToolOutputBytes?: number; startIndex?: number } = {},
): SessionMessage[] {
  return messages.flatMap((message, index): SessionMessage[] => {
    const timestampValue = Number.isFinite(message.timestamp) ? message.timestamp : 0;
    const base = {
      id: `${sessionId}:${timestampValue}:${index + (options.startIndex ?? 0)}`,
      timestamp: new Date(timestampValue).toISOString(),
    };

    if (message.role === "user") {
      return [{
        ...base,
        role: "user",
        content: normalizeUserContent(message.content),
      }];
    }

    if (message.role === "assistant") {
      return [{
        ...base,
        role: "assistant",
        content: normalizeContent(message.content),
        provider: message.provider,
        model: message.model,
        stopReason: message.stopReason,
        ...(message.errorMessage ? { errorMessage: message.errorMessage } : {}),
      }];
    }

    if (message.role === "toolResult") {
      const normalizedContent = normalizeToolResultContent(message.content);
      const output = normalizedToolOutput(message.content);
      const outputBytes = Buffer.byteLength(output);
      const contentBytes = Buffer.byteLength(JSON.stringify(normalizedContent));
      const maximumPreviewBytes = options.maxToolOutputBytes;
      const shouldPreview = maximumPreviewBytes !== undefined
        && Math.max(outputBytes, contentBytes) > maximumPreviewBytes;
      const preview = shouldPreview && maximumPreviewBytes !== undefined
        ? truncateUTF8Middle(output, maximumPreviewBytes) ?? output
        : undefined;
      return [{
        ...base,
        role: "tool",
        content: preview === undefined
          ? normalizedContent
          : [{ type: "text", text: preview }],
        toolCallId: message.toolCallId,
        toolName: message.toolName,
        isError: message.isError,
        ...(preview === undefined ? {} : {
          toolOutputTruncated: true,
          toolOutputBytes: Math.max(outputBytes, contentBytes),
        }),
      }];
    }

    if (message.role === "custom") {
      if (!message.display) return [];
      return [{
        ...base,
        role: "system",
        content: normalizeContent(message.content),
      }];
    }

    if (message.role === "bashExecution") {
      const output = message.output ? `\n${message.output}` : "";
      return [{
        ...base,
        role: "system",
        content: [{ type: "text", text: `$ ${message.command}${output}` }],
      }];
    }

    if (message.role === "branchSummary" || message.role === "compactionSummary") {
      return [{
        ...base,
        role: "system",
        content: [{ type: "text", text: message.summary }],
      }];
    }

    return [];
  });
}

function normalizeUserContent(content: unknown): SessionMessageContent[] {
  return normalizeContent(content).flatMap((item): SessionMessageContent[] => {
    if (item.type !== "text") return [item];
    const invocation = extractInjectedSkillBlocks(item.text);
    if (!invocation) return [item];
    return [
      ...invocation.skillNames.map((name): SessionMessageContent => ({ type: "skill", name })),
      ...(invocation.text ? [{ type: "text" as const, text: invocation.text }] : []),
    ];
  });
}

function extractInjectedSkillBlocks(
  text: string,
): { skillNames: string[]; text: string } | undefined {
  let remainder = text;
  const skillNames: string[] = [];
  let removedSkillBlock = false;

  while (true) {
    const openingTag = /^\s*<skill\b[^>]*>/.exec(remainder);
    if (!openingTag) {
      return removedSkillBlock
        ? { skillNames, text: remainder.trimStart() }
        : undefined;
    }

    const closingIndex = remainder.indexOf("</skill>", openingTag[0].length);
    if (closingIndex < 0) return undefined;

    const name = /\bname="([^"]+)"/.exec(openingTag[0])?.[1]?.trim();
    if (name && !skillNames.includes(name)) skillNames.push(name);

    remainder = remainder.slice(closingIndex + "</skill>".length);
    removedSkillBlock = true;
  }
}

function normalizeContent(content: unknown): SessionMessageContent[] {
  if (typeof content === "string") return [{ type: "text", text: content }];
  if (!Array.isArray(content)) return [];

  return content.flatMap((item): SessionMessageContent[] => {
    if (!item || typeof item !== "object" || !("type" in item)) return [];
    if (item.type === "text" && "text" in item && typeof item.text === "string") {
      return [{ type: "text", text: item.text }];
    }
    if (item.type === "thinking") {
      const redacted = "redacted" in item && item.redacted === true;
      return [{
        type: "thinking",
        thinking: redacted
          ? ""
          : ("thinking" in item && typeof item.thinking === "string" ? item.thinking : ""),
        redacted,
      }];
    }
    if (item.type === "image" && "mimeType" in item && typeof item.mimeType === "string") {
      return [{
        type: "image",
        mimeType: item.mimeType,
        ...("data" in item && typeof item.data === "string" ? { data: item.data } : {}),
      }];
    }
    if (
      item.type === "toolCall"
      && "id" in item
      && typeof item.id === "string"
      && "name" in item
      && typeof item.name === "string"
    ) {
      return [{
        type: "toolCall",
        id: item.id,
        name: item.name,
        argumentsSummary: safeJSONStringify("arguments" in item ? item.arguments : {}),
      }];
    }
    return [];
  });
}

function normalizeToolResultContent(content: unknown): SessionMessageContent[] {
  return normalizeContent(content).map((item) => {
    if (item.type !== "text") return item;
    return { ...item, text: stripTerminalFormatting(item.text) };
  });
}

function normalizedToolOutput(content: unknown): string {
  return normalizeToolResultContent(content)
    .map((item) => {
      if (item.type === "text") return item.text;
      if (item.type === "image") return `[image: ${item.mimeType}]`;
      if (item.type === "toolCall") return `${item.name} ${item.argumentsSummary}`;
      return "";
    })
    .filter(Boolean)
    .join("\n");
}

function truncateUTF8Middle(value: string, maximumBytes: number): string | undefined {
  const buffer = Buffer.from(value);
  if (buffer.byteLength <= maximumBytes) return undefined;

  const marker = Buffer.from("\n… [output truncated] …\n");
  const contentBudget = Math.max(0, maximumBytes - marker.byteLength);
  const headBytes = Math.ceil(contentBudget / 2);
  const tailBytes = Math.floor(contentBudget / 2);
  return Buffer.concat([
    buffer.subarray(0, headBytes),
    marker,
    buffer.subarray(buffer.byteLength - tailBytes),
  ]).toString("utf8");
}

function safeJSONStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? "{}";
  } catch {
    return "{}";
  }
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function toolResultDetails(result: unknown): Record<string, unknown> | undefined {
  return result && typeof result === "object" && "details" in result
    ? recordValue(result.details)
    : undefined;
}

function toolResultContent(result: unknown): SessionMessageContent[] {
  return result && typeof result === "object" && "content" in result
    ? normalizeToolResultContent(result.content)
    : [];
}

export function normalizeAgentSessionEvent(event: AgentSessionEvent): SessionHandleEvent | undefined {
  if (event.type === "message_start" && event.message.role === "assistant") {
    return { type: "assistantMessageStarted" };
  }

  if (event.type === "message_update") {
    const update = event.assistantMessageEvent;
    switch (update.type) {
      case "text_start":
        return {
          type: "assistantContent",
          phase: "start",
          contentType: "text",
          contentIndex: update.contentIndex,
        };
      case "text_delta":
        return {
          type: "assistantContent",
          phase: "delta",
          contentType: "text",
          contentIndex: update.contentIndex,
          delta: update.delta,
        };
      case "text_end":
        return {
          type: "assistantContent",
          phase: "end",
          contentType: "text",
          contentIndex: update.contentIndex,
          content: update.content,
        };
      case "thinking_start":
        return {
          type: "assistantContent",
          phase: "start",
          contentType: "thinking",
          contentIndex: update.contentIndex,
        };
      case "thinking_delta":
        return {
          type: "assistantContent",
          phase: "delta",
          contentType: "thinking",
          contentIndex: update.contentIndex,
          delta: update.delta,
        };
      case "thinking_end":
        return {
          type: "assistantContent",
          phase: "end",
          contentType: "thinking",
          contentIndex: update.contentIndex,
          content: update.content,
        };
      case "toolcall_start": {
        const toolCall = normalizeStreamingToolCall(update.partial.content[update.contentIndex]);
        return {
          type: "assistantContent",
          phase: "start",
          contentType: "toolCall",
          contentIndex: update.contentIndex,
          ...(toolCall ? { toolCall } : {}),
        };
      }
      case "toolcall_end":
        return {
          type: "assistantContent",
          phase: "end",
          contentType: "toolCall",
          contentIndex: update.contentIndex,
          toolCall: {
            id: update.toolCall.id,
            name: update.toolCall.name,
            argumentsSummary: safeJSONStringify(update.toolCall.arguments),
          },
        };
      default:
        break;
    }
  }

  if (event.type === "tool_execution_start") {
    return {
      type: "toolStarted",
      toolCallId: event.toolCallId,
      toolName: event.toolName,
      summary: JSON.stringify(event.args),
      rawInput: recordValue(event.args) ?? {},
    };
  }

  if (event.type === "tool_execution_update") {
    return {
      type: "toolUpdated",
      toolCallId: event.toolCallId,
      toolName: event.toolName,
      output: normalizeToolOutput(event.partialResult),
      content: toolResultContent(event.partialResult),
      ...(toolResultDetails(event.partialResult)
        ? { rawOutput: toolResultDetails(event.partialResult) }
        : {}),
    };
  }

  if (event.type === "tool_execution_end") {
    return {
      type: "toolCompleted",
      toolCallId: event.toolCallId,
      toolName: event.toolName,
      output: normalizeToolOutput(event.result),
      content: toolResultContent(event.result),
      ...(toolResultDetails(event.result) ? { rawOutput: toolResultDetails(event.result) } : {}),
      isError: event.isError,
    };
  }

  return undefined;
}

function normalizeStreamingToolCall(
  content: unknown,
): Extract<SessionHandleEvent, { type: "assistantContent" }>["toolCall"] {
  if (!content || typeof content !== "object" || !("type" in content)) return undefined;
  if (
    content.type !== "toolCall"
    || !("id" in content)
    || typeof content.id !== "string"
    || !("name" in content)
    || typeof content.name !== "string"
  ) {
    return undefined;
  }
  return {
    id: content.id,
    name: content.name,
    argumentsSummary: safeJSONStringify("arguments" in content ? content.arguments : {}),
  };
}

function normalizeToolOutput(result: unknown): string {
  if (result && typeof result === "object" && "content" in result) {
    const content = normalizeContent(result.content);
    const text = content.map((item) => {
      if (item.type === "text") return item.text;
      if (item.type === "image") return `[image · ${item.mimeType}]`;
      if (item.type === "skill") return "";
      if (item.type === "thinking") return "";
      return `${item.name} ${item.argumentsSummary}`;
    }).join("\n");
    if (text) return stripTerminalFormatting(text);
  }
  return stripTerminalFormatting(safeJSONStringify(result));
}

function stripTerminalFormatting(value: string): string {
  return value
    .replace(/\u001B(?:\][^\u0007]*(?:\u0007|\u001B\\)|\[[0-?]*[ -/]*[@-~])/g, "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n");
}
