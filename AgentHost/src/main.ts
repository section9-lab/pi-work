import packageMetadata from "../package.json";
import { extname, isAbsolute } from "node:path";
import { registerBunOAuthFlows } from "@earendil-works/pi-ai/bun-oauth";
import { getAgentDir, ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  flushRawStdout,
  takeOverStdout,
  writeRawStdout,
} from "../node_modules/@earendil-works/pi-coding-agent/dist/core/output-guard.js";
import {
  AgentSettingsCoordinator,
  agentDirectory,
  createAgentSettingsCoordinator,
  createAgentSettingsManager,
  type AgentSettingsPatch,
  type AgentTransport,
} from "./agent-settings.ts";
import {
  ExtensionPackagesCoordinator,
  createExtensionPackagesCoordinator,
  type ExtensionPackageScope,
} from "./extension-packages.ts";
import {
  ExtensionSettingsCoordinator,
  type ExtensionSettingsChange,
} from "./extension-settings.ts";
import {
  PROTOCOL_VERSION,
  PromptImagesError,
  parsePromptImages,
  type HostRequest,
  type HostResponse,
} from "./protocol.ts";
import {
  ACP_PROTOCOL_VERSION,
  adaptLegacyResultToACP,
  clientSupportsFormElicitation,
  createACPInitializeResult,
  createACPSessionConfigOptions,
  createACPSessionModeState,
  createACPSessionUpdate,
  decodeACPModelValue,
  encodeACPMessage,
  normalizeACPPromptContent,
  permissionDecisionFromACPResponse,
  type ACPRequest,
  type ACPResponse,
} from "./acp-protocol.ts";
import { ACPElicitationBroker } from "./acp-extension-ui.ts";
import { createPiSessionHandle, type SessionProfile } from "./pi-session-handle.ts";
import { listAvailableModels } from "./model-catalog.ts";
import { modelRuntimeOptions } from "./model-runtime-options.ts";
import { installProviderAuthOverrides } from "./provider-auth-overrides.ts";
import { listProviderSnapshots } from "./provider-catalog.ts";
import {
  ProviderAuthCoordinator,
  ProviderAuthCoordinatorError,
} from "./provider-auth-coordinator.ts";
import { SessionCatalog } from "./session-catalog.ts";
import {
  SessionRegistry,
  SessionRegistryError,
  type SessionModelOption,
  type SessionThinkingLevel,
} from "./session-registry.ts";
import {
  AccessPolicyError,
  type AccessMode,
} from "./access-policy.ts";
import { inspectGitBranches } from "./git-branches.ts";

Bun.env.PI_WORK_AGENT_HOST = "1";
takeOverStdout();
registerBunOAuthFlows();

function writeHostRecord(record: unknown): void {
  if (!record || typeof record !== "object" || Array.isArray(record)) return;
  const legacyRecord = record as Record<string, unknown>;
  if (legacyRecord.kind !== "event" || typeof legacyRecord.event !== "string") return;
  const payload = legacyRecord.payload;
  if (legacyRecord.event === "session.assistantContent") {
    const value = payload as Record<string, unknown>;
    if (value.contentType === "text" && typeof value.delta === "string") {
      writeRawStdout(encodeACPMessage(createACPSessionUpdate(String(value.sessionId), {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: value.delta },
      })));
      return;
    }
    if (value.contentType === "thinking" && typeof value.delta === "string") {
      writeRawStdout(encodeACPMessage(createACPSessionUpdate(String(value.sessionId), {
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: value.delta },
      })));
      return;
    }
  }
  if (legacyRecord.event === "session.toolStarted") {
    const value = payload as Record<string, unknown>;
    writeRawStdout(encodeACPMessage(createACPSessionUpdate(String(value.sessionId), {
      sessionUpdate: "tool_call",
      toolCallId: String(value.toolCallId),
      title: String(value.toolName),
      kind: "other",
      status: "in_progress",
      rawInput: value.rawInput && typeof value.rawInput === "object"
        ? value.rawInput
        : { summary: String(value.summary ?? "") },
    })));
    return;
  }
  if (legacyRecord.event === "session.toolUpdated" || legacyRecord.event === "session.toolCompleted") {
    const value = payload as Record<string, unknown>;
    const content = Array.isArray(value.content)
      ? value.content.flatMap((item): Record<string, unknown>[] => {
          if (!item || typeof item !== "object" || !("type" in item)) return [];
          if (item.type === "text" && "text" in item && typeof item.text === "string") {
            return [{ type: "content", content: { type: "text", text: item.text } }];
          }
          if (
            item.type === "image"
            && "mimeType" in item
            && typeof item.mimeType === "string"
          ) {
            return [{
              type: "content",
              content: {
                type: "image",
                mimeType: item.mimeType,
                ...("data" in item && typeof item.data === "string" ? { data: item.data } : {}),
              },
            }];
          }
          return [];
        })
      : [];
    writeRawStdout(encodeACPMessage(createACPSessionUpdate(String(value.sessionId), {
      sessionUpdate: "tool_call_update",
      toolCallId: String(value.toolCallId),
      status: legacyRecord.event === "session.toolCompleted"
        ? (value.isError === true ? "failed" : "completed")
        : "in_progress",
      content: content.length > 0 ? content : [{
          type: "content",
          content: { type: "text", text: String(value.output ?? "") },
        }],
      ...(value.rawOutput && typeof value.rawOutput === "object"
        ? { rawOutput: value.rawOutput }
        : {}),
      title: String(value.toolName),
    })));
    return;
  }
  if (legacyRecord.event === "session.planChanged") {
    const value = payload as Record<string, unknown>;
    writeRawStdout(encodeACPMessage(createACPSessionUpdate(String(value.sessionId), {
      sessionUpdate: "plan",
      entries: Array.isArray(value.entries) ? value.entries : [],
    })));
    return;
  }
  if (legacyRecord.event === "session.extensionStatusChanged") {
    const value = payload as Record<string, unknown>;
    writeRawStdout(encodeACPMessage(createACPSessionUpdate(String(value.sessionId), {
      sessionUpdate: "_piWork/extension_status",
      key: String(value.key),
      ...(typeof value.text === "string" ? { text: value.text } : {}),
    })));
    return;
  }
  if (legacyRecord.event === "session.extensionWidgetChanged") {
    const value = payload as Record<string, unknown>;
    writeRawStdout(encodeACPMessage(createACPSessionUpdate(String(value.sessionId), {
      sessionUpdate: "_piWork/extension_widget",
      key: String(value.key),
      ...(value.widget as Record<string, unknown> | undefined),
    })));
    return;
  }
  if (legacyRecord.event === "session.approvalRequested") {
    const value = payload as Record<string, unknown>;
    const permissionRequestId = `permission-${crypto.randomUUID()}`;
    pendingPermissionRequests.set(permissionRequestId, {
      sessionId: String(value.sessionId),
      requestId: String(value.requestId),
    });
    writeRawStdout(encodeACPMessage({
      jsonrpc: "2.0",
      id: permissionRequestId,
      method: "session/request_permission",
      params: {
        sessionId: String(value.sessionId),
        toolCall: {
          toolCallId: String(value.toolCallId),
          title: String(value.toolName),
          kind: "other",
          status: "pending",
          rawInput: { summary: String(value.summary ?? "") },
        },
        options: [
          { optionId: "allow-once", name: "Allow once", kind: "allow_once" },
          { optionId: "reject", name: "Reject", kind: "reject_once" },
        ],
      },
    }));
    return;
  }
  if (
    legacyRecord.event === "session.stateChanged"
    || legacyRecord.event === "session.messageDelta"
    || legacyRecord.event === "session.error"
  ) return;
  const value = payload as Record<string, unknown> | undefined;
  writeRawStdout(encodeACPMessage({
    jsonrpc: "2.0",
    method: `_piWork/${legacyRecord.event}`,
    params: value,
  }));
}

const hostVersion = Bun.env.PI_WORK_HOST_VERSION ?? packageMetadata.version;
const sessionCatalog = new SessionCatalog();
let modelRuntimePromise: Promise<ModelRuntime> | undefined;
let providerAuthCoordinatorPromise: Promise<ProviderAuthCoordinator> | undefined;
let agentSettingsCoordinator: AgentSettingsCoordinator | undefined;
let extensionPackagesCoordinator: ExtensionPackagesCoordinator | undefined;
let extensionSettingsCoordinator: ExtensionSettingsCoordinator | undefined;
let clientSupportsBooleanConfigOptions = false;
let clientSupportsACPFormElicitation = false;
const elicitationBroker = new ACPElicitationBroker((request) => {
  writeRawStdout(encodeACPMessage(request));
});
const sessionRegistry = new SessionRegistry((record) => {
  writeHostRecord({
    kind: "event",
    ...record,
  });
});
const pendingPermissionRequests = new Map<string, {
  sessionId: string;
  requestId: string;
}>();

async function acpSessionState(sessionId: string): Promise<{
  modes: Record<string, unknown>;
  configOptions: Record<string, unknown>[];
}> {
  const snapshot = sessionRegistry.snapshot(sessionId);
  return {
    modes: createACPSessionModeState(snapshot.accessMode),
    configOptions: createACPSessionConfigOptions(
      snapshot,
      await listAvailableModels(await getModelRuntime()),
    ).filter((option) => option.type !== "boolean" || clientSupportsBooleanConfigOptions),
  };
}

class HostRequestError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

async function handleRequest(request: HostRequest): Promise<HostResponse> {
  if (request.method === "settings.get") {
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: getAgentSettingsCoordinator().snapshot(),
    };
  }

  if (request.method === "settings.update") {
    const patch = parseAgentSettingsPatch(request.params?.patch);
    if (patch.defaultModel) {
      const model = (await getModelRuntime()).getModel(
        patch.defaultModel.provider,
        patch.defaultModel.modelId,
      );
      if (!model) {
        throw new HostRequestError(
          "model_not_found",
          `Model not found: ${patch.defaultModel.provider}/${patch.defaultModel.modelId}`,
        );
      }
    }
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: await getAgentSettingsCoordinator().update(patch),
    };
  }

  if (request.method === "extensions.listInstalled") {
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: await getExtensionPackagesCoordinator().list(),
    };
  }

  if (request.method === "extensions.install") {
    const source = parseCatalogExtensionSource(request.params);
    const snapshot = await getExtensionPackagesCoordinator().install(source);
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: {
        ...snapshot,
        reload: await sessionRegistry.reloadExtensions(),
      },
    };
  }

  if (request.method === "extensions.setEnabled") {
    const { source, scope } = parseExtensionPackageTarget(request.params);
    const enabled = request.params?.enabled;
    if (typeof enabled !== "boolean") {
      throw new Error("extensions.setEnabled requires a boolean enabled value");
    }
    const snapshot = await getExtensionPackagesCoordinator().setEnabled(
      source,
      scope,
      enabled,
    );
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: {
        ...snapshot,
        reload: await sessionRegistry.reloadExtensions(),
      },
    };
  }

  if (request.method === "extensions.update") {
    const { source } = parseExtensionPackageTarget(request.params);
    const snapshot = await getExtensionPackagesCoordinator().update(source);
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: {
        ...snapshot,
        reload: await sessionRegistry.reloadExtensions(),
      },
    };
  }

  if (request.method === "extensions.remove") {
    const { source, scope } = parseExtensionPackageTarget(request.params);
    const snapshot = await getExtensionPackagesCoordinator().remove(source, scope);
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: {
        ...snapshot,
        reload: await sessionRegistry.reloadExtensions(),
      },
    };
  }

  if (request.method === "extensions.settings.list") {
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: await getExtensionSettingsCoordinator().list(),
    };
  }

  if (request.method === "extensions.settings.update") {
    const { source, scope, changes } = parseExtensionSettingsUpdate(request.params);
    const settings = await getExtensionSettingsCoordinator().update(
      source,
      scope,
      changes,
    );
    await sessionRegistry.reloadExtensions();
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: settings,
    };
  }

  if (request.method === "sessions.list") {
    const cwd = request.params?.cwd;
    const sessionDirectory = request.params?.sessionDirectory;
    if (
      (cwd !== undefined && cwd !== null && typeof cwd !== "string")
      || (sessionDirectory !== undefined && typeof sessionDirectory !== "string")
    ) {
      throw new Error("sessions.list requires an optional string cwd and sessionDirectory");
    }

    const sessions = await sessionCatalog.list(
      typeof cwd === "string" ? cwd : undefined,
      sessionDirectory as string | undefined,
    );
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: { sessions },
    };
  }

  if (request.method === "git.branches") {
    const cwd = request.params?.cwd;
    if (typeof cwd !== "string") {
      throw new Error("git.branches requires a string cwd");
    }
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: await inspectGitBranches(cwd),
    };
  }

  if (request.method === "models.list") {
    const models = await listAvailableModels(await getModelRuntime());
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: { models },
    };
  }

  if (request.method === "providers.list") {
    const providers = await listProviderSnapshots(await getModelRuntime());
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: { providers },
    };
  }

  if (request.method === "auth.start") {
    const flowId = request.params?.flowId;
    const providerId = request.params?.providerId;
    const method = request.params?.method;
    if (
      typeof flowId !== "string"
      || typeof providerId !== "string"
      || (method !== "oauth" && method !== "api_key")
    ) {
      throw new Error("auth.start requires string flowId, providerId, and a valid method");
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: (await getProviderAuthCoordinator()).start({ flowId, providerId, method }),
    };
  }

  if (request.method === "auth.respond") {
    const flowId = request.params?.flowId;
    const promptId = request.params?.promptId;
    const value = request.params?.value;
    if (typeof flowId !== "string" || typeof promptId !== "string" || typeof value !== "string") {
      throw new Error("auth.respond requires string flowId, promptId, and value");
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: (await getProviderAuthCoordinator()).respond({ flowId, promptId, value }),
    };
  }

  if (request.method === "auth.cancel") {
    const flowId = request.params?.flowId;
    if (typeof flowId !== "string") {
      throw new Error("auth.cancel requires a string flowId");
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: (await getProviderAuthCoordinator()).cancel(flowId),
    };
  }

  if (request.method === "auth.logout") {
    const providerId = request.params?.providerId;
    if (typeof providerId !== "string") {
      throw new Error("auth.logout requires a string providerId");
    }

    const runtime = await getModelRuntime();
    const before = (await listProviderSnapshots(runtime)).find((provider) => provider.id === providerId);
    if (!before) {
      throw new HostRequestError("provider_not_found", `Unknown provider: ${providerId}`);
    }
    await (await getProviderAuthCoordinator()).logout(providerId);
    const provider = (await listProviderSnapshots(runtime)).find((entry) => entry.id === providerId);
    if (!provider) {
      throw new HostRequestError("provider_not_found", `Unknown provider: ${providerId}`);
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: {
        removed: before.status.canDisconnect,
        provider,
      },
    };
  }

  if (request.method === "session.createDraft") {
    const cwd = request.params?.cwd;
    const sessionDirectory = request.params?.sessionDirectory;
    const profile = request.params?.profile ?? "work";
    if (
      typeof cwd !== "string"
      || (sessionDirectory !== undefined && typeof sessionDirectory !== "string")
      || (profile !== "chat" && profile !== "work")
    ) {
      throw new Error("session.createDraft requires a string cwd and optional string sessionDirectory");
    }

    await getExtensionPackagesCoordinator().list();
    const draft = sessionCatalog.createDraft(cwd, sessionDirectory);
    const handle = await createPiSessionHandle({
      sessionManager: draft.manager,
      profile: profile as SessionProfile,
      modelRuntime: await getModelRuntime(),
      agentDir: agentDirectory(Bun.env),
      settingsManager: createAgentSettingsManager(cwd, Bun.env),
      ...(clientSupportsACPFormElicitation
        ? { requestElicitation: elicitationBroker.request }
        : {}),
    });
    sessionRegistry.register(handle);
    const state = await acpSessionState(handle.sessionId);
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: { session: draft.summary, ...state },
    };
  }

  if (request.method === "session.open") {
    let path = request.params?.path;
    const sessionId = request.params?.sessionId;
    const cwd = request.params?.cwd;
    const sessionDirectory = request.params?.sessionDirectory;
    const profile = request.params?.profile;
    if (
      (typeof path !== "string" && (typeof sessionId !== "string" || typeof cwd !== "string"))
      || (sessionDirectory !== undefined && typeof sessionDirectory !== "string")
      || (profile !== "chat" && profile !== "work")
    ) {
      throw new Error(
        "session.open requires either path or sessionId with cwd, optional sessionDirectory, and a valid profile",
      );
    }
    if (typeof path !== "string") {
      const summary = (await sessionCatalog.list(cwd as string, sessionDirectory as string | undefined))
        .find((candidate) => candidate.id === sessionId);
      if (!summary) throw new HostRequestError("session_not_found", `Session not found: ${sessionId}`);
      path = summary.path;
    }

    await getExtensionPackagesCoordinator().list();
    const manager = sessionCatalog.open(path as string, sessionDirectory as string | undefined);
    const existing = sessionRegistry.descriptor(manager.getSessionId());
    if (existing) {
      const state = await acpSessionState(existing.id);
      return {
        version: PROTOCOL_VERSION,
        kind: "response",
        id: request.id,
        ok: true,
        result: {
          sessionId: existing.id,
          path: existing.path,
          cwd: existing.cwd,
          ...state,
        },
      };
    }
    const handle = await createPiSessionHandle({
      sessionManager: manager,
      profile,
      modelRuntime: await getModelRuntime(),
      agentDir: agentDirectory(Bun.env),
      settingsManager: createAgentSettingsManager(manager.getCwd(), Bun.env),
      ...(clientSupportsACPFormElicitation
        ? { requestElicitation: elicitationBroker.request }
        : {}),
    });
    sessionRegistry.register(handle);
    const state = await acpSessionState(handle.sessionId);
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: {
        sessionId: manager.getSessionId(),
        path: manager.getSessionFile(),
        cwd: manager.getCwd(),
        ...state,
      },
    };
  }

  if (request.method === "session.snapshot") {
    const sessionId = request.params?.sessionId;
    if (typeof sessionId !== "string") {
      throw new Error("session.snapshot requires a string sessionId");
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: sessionRegistry.snapshot(sessionId),
    };
  }

  if (request.method === "session.exportHtml") {
    const sessionId = request.params?.sessionId;
    const path = request.params?.path;
    const sessionDirectory = request.params?.sessionDirectory;
    const profile = request.params?.profile;
    const outputPath = request.params?.outputPath;
    if (
      typeof sessionId !== "string"
      || typeof path !== "string"
      || (sessionDirectory !== undefined && typeof sessionDirectory !== "string")
      || (profile !== "chat" && profile !== "work")
      || typeof outputPath !== "string"
      || !isAbsolute(outputPath)
      || extname(outputPath).toLowerCase() !== ".html"
    ) {
      throw new Error(
        "session.exportHtml requires string sessionId/path, optional sessionDirectory, "
        + "a valid profile, and an absolute HTML outputPath",
      );
    }

    const existing = sessionRegistry.descriptor(sessionId);
    if (existing) {
      if (existing.path !== path) {
        throw new Error(`Session path does not match open session: ${sessionId}`);
      }
      return {
        version: PROTOCOL_VERSION,
        kind: "response",
        id: request.id,
        ok: true,
        result: await sessionRegistry.exportHtml(sessionId, outputPath),
      };
    }

    await getExtensionPackagesCoordinator().list();
    const manager = sessionCatalog.open(path, sessionDirectory);
    if (manager.getSessionId() !== sessionId) {
      throw new Error(`Session ID does not match file: ${sessionId}`);
    }
    const handle = await createPiSessionHandle({
      sessionManager: manager,
      profile,
      modelRuntime: await getModelRuntime(),
      agentDir: agentDirectory(Bun.env),
      settingsManager: createAgentSettingsManager(manager.getCwd(), Bun.env),
    });
    try {
      return {
        version: PROTOCOL_VERSION,
        kind: "response",
        id: request.id,
        ok: true,
        result: { sessionId, path: await handle.exportHtml(outputPath) },
      };
    } finally {
      handle.dispose();
    }
  }

  if (request.method === "session.transcriptPage") {
    const sessionId = request.params?.sessionId;
    const cursor = request.params?.cursor;
    const limit = request.params?.limit;
    if (
      typeof sessionId !== "string"
      || typeof cursor !== "string"
      || !Number.isSafeInteger(limit)
      || (limit as number) < 1
      || (limit as number) > 100
    ) {
      throw new Error(
        "session.transcriptPage requires string sessionId/cursor and an integer limit from 1 to 100",
      );
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: sessionRegistry.transcriptPage(sessionId, cursor, limit as number),
    };
  }

  if (request.method === "session.toolOutput") {
    const sessionId = request.params?.sessionId;
    const toolCallId = request.params?.toolCallId;
    if (typeof sessionId !== "string" || typeof toolCallId !== "string") {
      throw new Error("session.toolOutput requires string sessionId and toolCallId");
    }
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: {
        sessionId,
        toolCallId,
        output: sessionRegistry.toolOutput(sessionId, toolCallId),
      },
    };
  }

  if (request.method === "session.rename") {
    const sessionId = request.params?.sessionId;
    const title = request.params?.title;
    if (typeof sessionId !== "string" || typeof title !== "string" || title.trim().length === 0) {
      throw new Error("session.rename requires a string sessionId and non-empty title");
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: sessionRegistry.rename(sessionId, title.trim()),
    };
  }

  if (request.method === "session.setGitBranch") {
    const sessionId = request.params?.sessionId;
    const branch = request.params?.branch;
    if (typeof sessionId !== "string" || typeof branch !== "string" || !branch.trim()) {
      throw new Error("session.setGitBranch requires a string sessionId and non-empty branch");
    }
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: sessionRegistry.setGitBranch(sessionId, branch),
    };
  }

  if (request.method === "session.commands") {
    const sessionId = request.params?.sessionId;
    if (typeof sessionId !== "string") {
      throw new Error("session.commands requires a string sessionId");
    }
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: { commands: sessionRegistry.commands(sessionId) },
    };
  }

  if (request.method === "session.setModel") {
    const sessionId = request.params?.sessionId;
    const provider = request.params?.provider;
    const modelId = request.params?.modelId;
    if (typeof sessionId !== "string" || typeof provider !== "string" || typeof modelId !== "string") {
      throw new Error("session.setModel requires string sessionId, provider, and modelId");
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: await sessionRegistry.setModel(sessionId, provider, modelId),
    };
  }

  if (request.method === "session.setConfigOption") {
    const sessionId = request.params?.sessionId;
    const configId = request.params?.configId;
    const value = request.params?.value;
    if (typeof sessionId !== "string" || typeof configId !== "string") {
      throw new Error("session.setConfigOption requires string sessionId and configId");
    }
    if (configId === "model" && typeof value === "string") {
      const model = decodeACPModelValue(value);
      if (!model) throw new Error("model config value must contain provider/modelId");
      await sessionRegistry.setModel(sessionId, model.provider, model.modelId);
    } else if (configId === "thought_level" && isThinkingLevel(value)) {
      sessionRegistry.setThinkingLevel(sessionId, value);
    } else if (configId === "fast_mode" && typeof value === "boolean") {
      await sessionRegistry.setModelOption(sessionId, "fastMode", value);
    } else if (configId === "one_million_context" && typeof value === "boolean") {
      await sessionRegistry.setModelOption(sessionId, "oneMillionContext", value);
    } else {
      throw new HostRequestError(
        "unsupported_config_option",
        `Unsupported session config option: ${configId}`,
      );
    }
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: { configOptions: (await acpSessionState(sessionId)).configOptions },
    };
  }

  if (request.method === "session.setThinkingLevel") {
    const sessionId = request.params?.sessionId;
    const thinkingLevel = request.params?.thinkingLevel;
    if (typeof sessionId !== "string" || !isThinkingLevel(thinkingLevel)) {
      throw new Error(
        "session.setThinkingLevel requires a string sessionId and valid thinkingLevel",
      );
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: sessionRegistry.setThinkingLevel(sessionId, thinkingLevel),
    };
  }

  if (request.method === "session.setModelOption") {
    const sessionId = request.params?.sessionId;
    const option = request.params?.option;
    const enabled = request.params?.enabled;
    if (typeof sessionId !== "string" || !isModelOption(option) || typeof enabled !== "boolean") {
      throw new Error(
        "session.setModelOption requires a string sessionId, valid option, and boolean enabled",
      );
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: await sessionRegistry.setModelOption(sessionId, option, enabled),
    };
  }

  if (request.method === "session.setAccessMode") {
    const sessionId = request.params?.sessionId;
    const accessMode = request.params?.accessMode;
    if (typeof sessionId !== "string" || !isAccessMode(accessMode) || accessMode === "none") {
      throw new Error("session.setAccessMode requires a string sessionId and a Work access mode");
    }

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: sessionRegistry.setAccessMode(sessionId, accessMode),
    };
  }

  if (request.method === "session.prompt") {
    const sessionId = request.params?.sessionId;
    const turnId = request.params?.turnId;
    const text = request.params?.text;
    if (typeof sessionId !== "string" || typeof turnId !== "string" || typeof text !== "string") {
      throw new Error("session.prompt requires string sessionId, turnId, and text");
    }
    const images = parsePromptImages(request.params?.images);

    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: sessionRegistry.prompt(sessionId, turnId, text, images),
    };
  }

  if (request.method === "session.abort") {
    const sessionId = request.params?.sessionId;
    if (typeof sessionId !== "string") {
      throw new Error("session.abort requires a string sessionId");
    }

    await sessionRegistry.abort(sessionId);
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: { aborted: true, sessionId },
    };
  }

  if (request.method === "session.close") {
    const sessionId = request.params?.sessionId;
    if (typeof sessionId !== "string") {
      throw new Error("session.close requires a string sessionId");
    }

    await sessionRegistry.closeSession(sessionId);
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: { closed: true, sessionId },
    };
  }

  if (request.method === "session.delete") {
    const sessionId = request.params?.sessionId;
    let cwd = request.params?.cwd;
    const sessionDirectory = request.params?.sessionDirectory;
    if (
      typeof sessionId !== "string"
      || (cwd !== undefined && typeof cwd !== "string")
      || (sessionDirectory !== undefined && typeof sessionDirectory !== "string")
    ) {
      throw new Error(
        "session.delete requires string sessionId and optional cwd/sessionDirectory",
      );
    }

    const openSession = sessionRegistry.descriptor(sessionId);
    if (cwd === undefined) {
      cwd = openSession?.cwd
        ?? (await sessionCatalog.list(undefined, sessionDirectory as string | undefined))
          .find((candidate) => candidate.id === sessionId)?.cwd;
    }
    if (typeof cwd !== "string") {
      throw new HostRequestError("session_not_found", `Session not found: ${sessionId}`);
    }
    if (openSession && openSession.cwd !== cwd) {
      throw new Error(`Session does not belong to cwd: ${cwd}`);
    }
    if (openSession) await sessionRegistry.closeSession(sessionId);
    await sessionCatalog.delete(sessionId, cwd, sessionDirectory, openSession);
    return {
      version: PROTOCOL_VERSION,
      kind: "response",
      id: request.id,
      ok: true,
      result: { deleted: true, sessionId },
    };
  }

  throw new HostRequestError("method_not_found", `Unsupported method: ${request.method}`);
}

function getModelRuntime(): Promise<ModelRuntime> {
  modelRuntimePromise ??= ModelRuntime.create(modelRuntimeOptions(Bun.env)).then((runtime) => {
    installProviderAuthOverrides(runtime);
    return runtime;
  });
  return modelRuntimePromise;
}

function getProviderAuthCoordinator(): Promise<ProviderAuthCoordinator> {
  providerAuthCoordinatorPromise ??= getModelRuntime().then((runtime) => (
    new ProviderAuthCoordinator(runtime, (event) => {
      writeHostRecord({
        version: PROTOCOL_VERSION,
        kind: "event",
        ...event,
      });
    })
  ));
  return providerAuthCoordinatorPromise;
}

function getAgentSettingsCoordinator(): AgentSettingsCoordinator {
  agentSettingsCoordinator ??= createAgentSettingsCoordinator(
    Bun.env.HOME ?? process.cwd(),
    Bun.env,
  );
  return agentSettingsCoordinator;
}

function getExtensionPackagesCoordinator(): ExtensionPackagesCoordinator {
  extensionPackagesCoordinator ??= createExtensionPackagesCoordinator(
    Bun.env.HOME ?? process.cwd(),
    Bun.env,
  );
  return extensionPackagesCoordinator;
}

function getExtensionSettingsCoordinator(): ExtensionSettingsCoordinator {
  extensionSettingsCoordinator ??= new ExtensionSettingsCoordinator(
    agentDirectory(Bun.env) ?? getAgentDir(),
    () => getExtensionPackagesCoordinator().list(),
  );
  return extensionSettingsCoordinator;
}

function parseExtensionPackageTarget(
  params: Record<string, unknown> | undefined,
): { source: string; scope: ExtensionPackageScope } {
  const source = params?.source;
  const scope = params?.scope;
  if (typeof source !== "string" || source.trim().length === 0) {
    throw new Error("Extension package source must be a non-empty string");
  }
  if (scope !== "user" && scope !== "project") {
    throw new Error("Extension package scope must be user or project");
  }
  return { source, scope };
}

function parseExtensionSettingsUpdate(
  params: Record<string, unknown> | undefined,
): {
  source: string;
  scope: ExtensionPackageScope;
  changes: ExtensionSettingsChange[];
} {
  const { source, scope } = parseExtensionPackageTarget(params);
  const rawChanges = params?.changes;
  if (!Array.isArray(rawChanges) || rawChanges.length === 0) {
    throw new Error("extensions.settings.update requires at least one change");
  }
  const changes = rawChanges.map((raw): ExtensionSettingsChange => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error("Each extension setting change must be an object");
    }
    const path = "path" in raw ? raw.path : undefined;
    const operation = "operation" in raw ? raw.operation : undefined;
    const value = "value" in raw ? raw.value : undefined;
    if (typeof path !== "string" || !path.startsWith("/") || path.length < 2) {
      throw new Error("Each extension setting change requires a JSON Pointer path");
    }
    if (operation === "remove") {
      if (value !== undefined) {
        throw new Error("A remove setting change must not include a value");
      }
      return { path, operation };
    }
    if (operation !== "set" || typeof value !== "string") {
      throw new Error("A set setting change requires a string value");
    }
    return { path, operation, value };
  });
  return { source, scope, changes };
}

function parseCatalogExtensionSource(
  params: Record<string, unknown> | undefined,
): string {
  const source = params?.source;
  if (typeof source !== "string"
    || !/^npm:(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/i.test(source)) {
    throw new Error("Catalog extensions must use an npm source");
  }
  return source;
}

function isAccessMode(value: unknown): value is AccessMode {
  return value === "none" || value === "readOnly" || value === "ask" || value === "full";
}

function isThinkingLevel(value: unknown): value is SessionThinkingLevel {
  return value === "off"
    || value === "minimal"
    || value === "low"
    || value === "medium"
    || value === "high"
    || value === "xhigh"
    || value === "max";
}

function parseAgentSettingsPatch(value: unknown): AgentSettingsPatch {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("settings.update requires a settings patch object");
  }
  const raw = value as Record<string, unknown>;
  const patch: AgentSettingsPatch = {};
  if (raw.defaultModel !== undefined) {
    if (!raw.defaultModel || typeof raw.defaultModel !== "object" || Array.isArray(raw.defaultModel)) {
      throw new Error("defaultModel must contain provider and modelId");
    }
    const model = raw.defaultModel as Record<string, unknown>;
    if (typeof model.provider !== "string" || typeof model.modelId !== "string") {
      throw new Error("defaultModel must contain provider and modelId");
    }
    patch.defaultModel = { provider: model.provider, modelId: model.modelId };
  }
  if (raw.defaultThinkingLevel !== undefined) {
    if (!isThinkingLevel(raw.defaultThinkingLevel)) {
      throw new Error("defaultThinkingLevel is invalid");
    }
    patch.defaultThinkingLevel = raw.defaultThinkingLevel;
  }
  if (raw.transport !== undefined) {
    if (!isTransport(raw.transport)) throw new Error("transport is invalid");
    patch.transport = raw.transport;
  }
  if (raw.compactionEnabled !== undefined) {
    if (typeof raw.compactionEnabled !== "boolean") {
      throw new Error("compactionEnabled must be a boolean");
    }
    patch.compactionEnabled = raw.compactionEnabled;
  }
  if (raw.retryEnabled !== undefined) {
    if (typeof raw.retryEnabled !== "boolean") {
      throw new Error("retryEnabled must be a boolean");
    }
    patch.retryEnabled = raw.retryEnabled;
  }
  return patch;
}

function isTransport(value: unknown): value is AgentTransport {
  return value === "auto"
    || value === "sse"
    || value === "websocket"
    || value === "websocket-cached";
}

function isModelOption(value: unknown): value is SessionModelOption {
  return value === "fastMode" || value === "oneMillionContext";
}

async function handleLine(line: string): Promise<void> {
  if (line.length === 0) return;

  let request: ACPRequest | undefined;
  try {
    const message = JSON.parse(line) as Partial<ACPRequest & ACPResponse>;
    if (message.jsonrpc !== "2.0") {
      throw new Error("Invalid JSON-RPC request");
    }
    if (typeof message.method !== "string") {
      if (message.id !== undefined) {
        if (elicitationBroker.resolve(message as ACPResponse)) return;
        const permissionRequestId = String(message.id);
        const pending = pendingPermissionRequests.get(permissionRequestId);
        if (pending) {
          const decision = permissionDecisionFromACPResponse(message as ACPResponse);
          if (decision) {
            pendingPermissionRequests.delete(permissionRequestId);
            sessionRegistry.resolveApproval(pending.sessionId, pending.requestId, decision);
          }
        }
        return;
      }
      throw new Error("Invalid JSON-RPC request");
    }
    if (message.id === undefined) {
      if (message.method === "session/cancel") {
        try {
          await handleRequest(normalizeACPRequest({
            ...message,
            id: "__notification__",
          } as ACPRequest));
        } catch {
          // JSON-RPC notifications never receive success or error responses.
        }
      }
      return;
    }
    request = message as ACPRequest;

    if (request.method === "initialize") {
      clientSupportsACPFormElicitation = clientSupportsFormElicitation(request.params);
      const capabilities = request.params && typeof request.params === "object"
        ? (request.params as Record<string, unknown>).clientCapabilities
        : undefined;
      const session = capabilities && typeof capabilities === "object"
        ? (capabilities as Record<string, unknown>).session
        : undefined;
      const configOptions = session && typeof session === "object"
        ? (session as Record<string, unknown>).configOptions
        : undefined;
      clientSupportsBooleanConfigOptions = Boolean(
        configOptions
        && typeof configOptions === "object"
        && (configOptions as Record<string, unknown>).boolean,
      );
      writeRawStdout(encodeACPMessage({
        jsonrpc: "2.0",
        id: request.id,
        result: createACPInitializeResult({
          hostVersion,
        }),
      }));
      return;
    }

    const internalRequest = normalizeACPRequest(request);
    const response = await handleRequest(internalRequest);
    let result = adaptLegacyResultToACP(request.method, unwrapLegacyResult(response));
    if (request.method === "session/prompt") {
      const sessionId = internalRequest.params?.sessionId;
      const turnId = internalRequest.params?.turnId;
      if (typeof sessionId !== "string" || typeof turnId !== "string") {
        throw new Error("session/prompt requires sessionId and turnId");
      }
      result = {
        stopReason: await sessionRegistry.promptCompletion(sessionId, turnId),
      };
    }
    writeRawStdout(encodeACPMessage({
      jsonrpc: "2.0",
      id: request.id,
      result,
    }));
  } catch (error) {
    const response: ACPResponse = {
      jsonrpc: "2.0",
      id: request?.id ?? null,
      error: {
        code: -32000,
        message: error instanceof Error ? error.message : String(error),
        data: {
          code: error instanceof HostRequestError
            || error instanceof PromptImagesError
            || error instanceof SessionRegistryError
            || error instanceof AccessPolicyError
            || error instanceof ProviderAuthCoordinatorError
            ? error.code
            : "invalid_request",
        },
      },
    };
    writeRawStdout(encodeACPMessage(response));
  }
}

function unwrapLegacyResult(response: HostResponse): unknown {
  if (!response.ok) {
    throw new HostRequestError(
      response.error?.code ?? "request_failed",
      response.error?.message ?? "Agent Host request failed",
    );
  }
  return response.result;
}

function normalizeACPRequest(request: ACPRequest): HostRequest {
  const methodMap: Record<string, string> = {
    "session/list": "sessions.list",
    "session/new": "session.createDraft",
    "session/load": "session.open",
    "session/resume": "session.open",
    "session/prompt": "session.prompt",
    "session/cancel": "session.abort",
    "session/close": "session.close",
    "session/delete": "session.delete",
    "session/set_mode": "session.setAccessMode",
    "session/set_config_option": "session.setConfigOption",
    "_piWork/models/list": "models.list",
    "_piWork/providers/list": "providers.list",
    "_piWork/auth/start": "auth.start",
    "_piWork/auth/respond": "auth.respond",
    "_piWork/auth/cancel": "auth.cancel",
    "_piWork/auth/logout": "auth.logout",
    "_piWork/settings/get": "settings.get",
    "_piWork/settings/update": "settings.update",
    "_piWork/extensions/listInstalled": "extensions.listInstalled",
    "_piWork/extensions/install": "extensions.install",
    "_piWork/extensions/setEnabled": "extensions.setEnabled",
    "_piWork/extensions/update": "extensions.update",
    "_piWork/extensions/remove": "extensions.remove",
    "_piWork/extensions/settings/list": "extensions.settings.list",
    "_piWork/extensions/settings/update": "extensions.settings.update",
    "_piWork/git/branches": "git.branches",
    "_piWork/session/exportHtml": "session.exportHtml",
    "_piWork/session/snapshot": "session.snapshot",
    "_piWork/session/transcriptPage": "session.transcriptPage",
    "_piWork/session/toolOutput": "session.toolOutput",
    "_piWork/session/commands": "session.commands",
    "_piWork/session/rename": "session.rename",
    "_piWork/session/setGitBranch": "session.setGitBranch",
  };
  const method = methodMap[request.method] ?? request.method;
  const params = normalizeACPParams(request.method, request.params);
  return {
    version: PROTOCOL_VERSION,
    kind: "request",
    id: String(request.id),
    method,
    params: params as Record<string, unknown> | undefined,
  };
}

function normalizeACPParams(method: string, params: unknown): unknown {
  if (!params || typeof params !== "object" || Array.isArray(params)) return params;
  const value = params as Record<string, unknown>;
  const metadata = value._meta && typeof value._meta === "object"
    ? value._meta as Record<string, unknown>
    : {};
  const piWorkMetadata = metadata.piWork && typeof metadata.piWork === "object"
    ? metadata.piWork as Record<string, unknown>
    : metadata;
  if (method === "session/list") {
    return {
      cwd: value.cwd,
      sessionDirectory: piWorkMetadata.sessionDirectory,
    };
  }
  if (method === "session/new") {
    return {
      cwd: value.cwd,
      sessionDirectory: piWorkMetadata.sessionDirectory,
      profile: piWorkMetadata.profile ?? "work",
    };
  }
  if (method === "session/load" || method === "session/resume") {
    return {
      sessionId: value.sessionId,
      cwd: value.cwd,
      sessionDirectory: piWorkMetadata.sessionDirectory,
      profile: piWorkMetadata.profile ?? "work",
    };
  }
  if (method === "session/prompt") {
    const prompt = Array.isArray(value.prompt) ? value.prompt : [];
    const content = normalizeACPPromptContent(prompt);
    const meta = value._meta && typeof value._meta === "object"
      ? value._meta as Record<string, unknown>
      : {};
    return {
      sessionId: value.sessionId,
      turnId: typeof meta.turnId === "string" ? meta.turnId : crypto.randomUUID(),
      text: content.text,
      images: content.images,
    };
  }
  if (method === "session/cancel") return { sessionId: value.sessionId };
  if (method === "session/close") return { sessionId: value.sessionId };
  if (method === "session/delete") return {
    sessionId: value.sessionId,
    sessionDirectory: piWorkMetadata.sessionDirectory,
  };
  if (method === "session/set_mode") return {
    sessionId: value.sessionId,
    accessMode: value.modeId,
  };
  return params;
}

const decoder = new TextDecoder();
let inputBuffer = "";

for await (const chunk of Bun.stdin.stream()) {
  inputBuffer += decoder.decode(chunk, { stream: true });

  let newlineIndex = inputBuffer.indexOf("\n");
  while (newlineIndex >= 0) {
    let line = inputBuffer.slice(0, newlineIndex);
    inputBuffer = inputBuffer.slice(newlineIndex + 1);
    if (line.endsWith("\r")) line = line.slice(0, -1);
    await handleLine(line);
    newlineIndex = inputBuffer.indexOf("\n");
  }
}

sessionRegistry.closeAll();
await flushRawStdout();
