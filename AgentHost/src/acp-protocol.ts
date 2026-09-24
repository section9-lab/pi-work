/**
 * The wire contract for the app is ACP v1 over newline-delimited JSON-RPC 2.0.
 * Keep this module deliberately small: domain coordinators own validation and
 * this module only owns transport envelopes and protocol-shaped helpers.
 */

export const ACP_PROTOCOL_VERSION = 1 as const;

export const PI_WORK_CAPABILITIES = [
  "models.list",
  "providers.list",
  "auth.start",
  "auth.respond",
  "auth.cancel",
  "auth.logout",
  "settings.get",
  "settings.update",
  "extensions.listInstalled",
  "extensions.install",
  "extensions.setEnabled",
  "extensions.update",
  "extensions.remove",
  "extensions.settings.list",
  "extensions.settings.update",
  "git.branches",
  "session.exportHtml",
  "session.snapshot",
  "session.transcriptPage",
  "session.toolOutput",
  "session.commands",
  "session.rename",
  "session.setGitBranch",
  "session.extensionStatus",
  "session.extensionWidget",
] as const;

export type ACPRequest = {
  jsonrpc: "2.0";
  id: string | number;
  method: string;
  params?: unknown;
};

export type ACPResponse = {
  jsonrpc: "2.0";
  id: string | number | null;
  result?: unknown;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
};

export type ACPNotification = {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
};

export type ACPMessage = ACPRequest | ACPResponse | ACPNotification;

export type ACPSessionUpdate = {
  sessionUpdate: string;
  [key: string]: unknown;
};

export type ACPDecodedSessionUpdate = {
  kind: "session_update";
  sessionId: string;
  updateType: string;
  rawUpdate: ACPSessionUpdate;
};

export type ACPDecodedMessage =
  | { kind: "request"; message: ACPRequest }
  | { kind: "response"; message: ACPResponse }
  | { kind: "notification"; message: ACPNotification }
  | ACPDecodedSessionUpdate;

export function clientSupportsFormElicitation(params: unknown): boolean {
  if (!params || typeof params !== "object" || Array.isArray(params)) return false;
  const capabilities = (params as Record<string, unknown>).clientCapabilities;
  if (!capabilities || typeof capabilities !== "object" || Array.isArray(capabilities)) {
    return false;
  }
  const elicitation = (capabilities as Record<string, unknown>).elicitation;
  if (!elicitation || typeof elicitation !== "object" || Array.isArray(elicitation)) {
    return false;
  }
  const form = (elicitation as Record<string, unknown>).form;
  return Boolean(form && typeof form === "object" && !Array.isArray(form));
}

export function encodeACPMessage(message: ACPMessage): string {
  return `${JSON.stringify(message)}\n`;
}

export function createACPSessionUpdate(
  sessionId: string,
  update: ACPSessionUpdate,
): ACPNotification {
  return {
    jsonrpc: "2.0",
    method: "session/update",
    params: { sessionId, update },
  };
}

export function createACPInitializeResult(options: {
  hostVersion: string;
}): Record<string, unknown> {
  return {
    protocolVersion: ACP_PROTOCOL_VERSION,
    agentInfo: {
      name: "pi-work-agent-host",
      version: options.hostVersion,
    },
    agentCapabilities: {
      promptCapabilities: {
        image: true,
        audio: false,
        embeddedContext: false,
      },
      mcpCapabilities: {
        http: false,
        sse: false,
      },
      sessionCapabilities: {
        list: {},
        delete: {},
        resume: {},
        close: {},
      },
    },
    authMethods: [],
    _meta: {
      piWork: {
        extensions: true,
        capabilities: PI_WORK_CAPABILITIES,
      },
    },
  };
}

type ACPModelChoice = {
  provider: string;
  id: string;
  name: string;
};

type ACPSessionConfiguration = {
  model: ACPModelChoice | null;
  thinkingLevel: string;
  availableThinkingLevels: string[];
  modelOptions: {
    fastMode: { supported: boolean; enabled: boolean };
    oneMillionContext: { supported: boolean; enabled: boolean };
  };
};

export function encodeACPModelValue(provider: string, modelId: string): string {
  return `${provider}/${modelId}`;
}

export function decodeACPModelValue(
  value: string,
): { provider: string; modelId: string } | undefined {
  const separator = value.indexOf("/");
  if (separator <= 0 || separator === value.length - 1) return undefined;
  return {
    provider: value.slice(0, separator),
    modelId: value.slice(separator + 1),
  };
}

export function createACPSessionConfigOptions(
  state: ACPSessionConfiguration,
  availableModels: ACPModelChoice[] = [],
): Record<string, unknown>[] {
  const options: Record<string, unknown>[] = [];
  if (state.model) {
    const models = availableModels.some((model) => (
      model.provider === state.model?.provider && model.id === state.model.id
    ))
      ? availableModels
      : [state.model, ...availableModels];
    options.push({
      id: "model",
      name: "Model",
      category: "model",
      type: "select",
      currentValue: encodeACPModelValue(state.model.provider, state.model.id),
      options: models.map((model) => ({
        value: encodeACPModelValue(model.provider, model.id),
        name: model.name,
      })),
    });
  }
  if (state.availableThinkingLevels.length > 0) {
    options.push({
      id: "thought_level",
      name: "Thinking level",
      category: "thought_level",
      type: "select",
      currentValue: state.thinkingLevel,
      options: state.availableThinkingLevels.map((level) => ({ value: level, name: level })),
    });
  }
  if (state.modelOptions.fastMode.supported) {
    options.push({
      id: "fast_mode",
      name: "Fast mode",
      category: "model_config",
      type: "boolean",
      currentValue: state.modelOptions.fastMode.enabled,
    });
  }
  if (state.modelOptions.oneMillionContext.supported) {
    options.push({
      id: "one_million_context",
      name: "1M context",
      category: "model_config",
      type: "boolean",
      currentValue: state.modelOptions.oneMillionContext.enabled,
    });
  }
  return options;
}

export function createACPSessionModeState(accessMode: string): Record<string, unknown> {
  const modes = accessMode === "none"
    ? [{ id: "none", name: "Chat" }]
    : [
        { id: "readOnly", name: "Read only" },
        { id: "ask", name: "Ask before changes" },
        { id: "full", name: "Full access" },
      ];
  return { currentModeId: accessMode, availableModes: modes };
}

export function normalizeACPPromptContent(prompt: unknown[]): {
  text: string;
  images: { mimeType: string; data: string }[];
} {
  const text: string[] = [];
  const images: { mimeType: string; data: string }[] = [];
  for (const item of prompt) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const content = item as Record<string, unknown>;
    if (content.type === "text" && typeof content.text === "string") {
      text.push(content.text);
    } else if (
      content.type === "resource_link"
      && typeof content.name === "string"
      && typeof content.uri === "string"
    ) {
      text.push(`\n\n[${content.name}](${content.uri})`);
    } else if (
      content.type === "image"
      && typeof content.mimeType === "string"
      && typeof content.data === "string"
    ) {
      images.push({ mimeType: content.mimeType, data: content.data });
    }
  }
  return { text: text.join(""), images };
}

export function adaptLegacyResultToACP(method: string, result: unknown): unknown {
  const value = asRecord(result, `${method} result`);
  if (method === "session/new") {
    const session = asRecord(value.session, "session/new result.session");
    if (typeof session.id !== "string") {
      throw new Error("session/new result requires session.id");
    }
    return {
      sessionId: session.id,
      ...(value.modes ? { modes: value.modes } : {}),
      ...(value.configOptions ? { configOptions: value.configOptions } : {}),
    };
  }
  if (method === "session/list") {
    if (!Array.isArray(value.sessions)) {
      throw new Error("session/list result requires sessions");
    }
    return {
      sessions: value.sessions.map((entry) => {
        const session = asRecord(entry, "session/list session");
        if (typeof session.id !== "string" || typeof session.cwd !== "string") {
          throw new Error("session/list sessions require id and cwd");
        }
        return {
          sessionId: session.id,
          cwd: session.cwd,
          ...(typeof session.title === "string" ? { title: session.title } : {}),
          ...(typeof session.modifiedAt === "string" ? { updatedAt: session.modifiedAt } : {}),
        };
      }),
    };
  }
  if (method === "session/load" || method === "session/resume") {
    return {
      ...(value.modes ? { modes: value.modes } : {}),
      ...(value.configOptions ? { configOptions: value.configOptions } : {}),
    };
  }
  if (
    method === "session/close"
    || method === "session/delete"
    || method === "session/set_mode"
  ) {
    return {};
  }
  return result;
}

export function permissionDecisionFromACPResponse(
  response: ACPResponse,
): "allowOnce" | "deny" | undefined {
  if (response.error) return "deny";
  const result = response.result;
  if (!result || typeof result !== "object" || Array.isArray(result)) return undefined;
  const outcome = (result as Record<string, unknown>).outcome;
  if (!outcome || typeof outcome !== "object" || Array.isArray(outcome)) return undefined;
  const value = outcome as Record<string, unknown>;
  if (value.outcome === "cancelled") return "deny";
  if (value.outcome !== "selected" || typeof value.optionId !== "string") return undefined;
  return value.optionId === "allow-once" ? "allowOnce" : "deny";
}

export function decodeACPMessage(line: string): ACPDecodedMessage {
  const message = JSON.parse(line) as Record<string, unknown>;
  if (message.jsonrpc !== "2.0") {
    throw new Error("Invalid JSON-RPC version");
  }

  if (message.method === "session/update") {
    const params = asRecord(message.params, "session/update params");
    const sessionId = params.sessionId;
    const update = asRecord(params.update, "session/update update");
    const updateType = update.sessionUpdate;
    if (typeof sessionId !== "string" || typeof updateType !== "string") {
      throw new Error("session/update requires sessionId and update.sessionUpdate");
    }
    return {
      kind: "session_update",
      sessionId,
      updateType,
      rawUpdate: update as ACPSessionUpdate,
    };
  }

  if (typeof message.method === "string") {
    if (message.id !== undefined) {
      return { kind: "request", message: message as unknown as ACPRequest };
    }
    return { kind: "notification", message: message as unknown as ACPNotification };
  }

  if (message.id !== undefined || message.error !== undefined || message.result !== undefined) {
    return { kind: "response", message: message as unknown as ACPResponse };
  }

  throw new Error("Invalid JSON-RPC message");
}

function asRecord(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value as Record<string, unknown>;
}
