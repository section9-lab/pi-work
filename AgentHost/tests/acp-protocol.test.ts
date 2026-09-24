import { describe, expect, test } from "bun:test";

import {
  ACP_PROTOCOL_VERSION,
  adaptLegacyResultToACP,
  clientSupportsFormElicitation,
  createACPInitializeResult,
  createACPSessionConfigOptions,
  decodeACPModelValue,
  createACPSessionUpdate,
  decodeACPMessage,
  encodeACPMessage,
  normalizeACPPromptContent,
  permissionDecisionFromACPResponse,
} from "../src/acp-protocol.ts";

describe("ACP v1 JSON-RPC protocol", () => {
  test("detects only explicitly advertised ACP form elicitation support", () => {
    expect(clientSupportsFormElicitation({
      clientCapabilities: { elicitation: { form: {} } },
    })).toBe(true);
    expect(clientSupportsFormElicitation({
      clientCapabilities: { elicitation: { url: {} } },
    })).toBe(false);
    expect(clientSupportsFormElicitation({ clientCapabilities: {} })).toBe(false);
  });

  test("encodes an initialize request as JSON-RPC 2.0", () => {
    const line = encodeACPMessage({
      jsonrpc: "2.0",
      id: "initialize-1",
      method: "initialize",
      params: {
        protocolVersion: ACP_PROTOCOL_VERSION,
        clientInfo: { name: "pi-work", version: "0.1.0" },
        clientCapabilities: {},
      },
    });

    expect(line.endsWith("\n")).toBe(true);
    expect(JSON.parse(line)).toEqual({
      jsonrpc: "2.0",
      id: "initialize-1",
      method: "initialize",
      params: {
        protocolVersion: 1,
        clientInfo: { name: "pi-work", version: "0.1.0" },
        clientCapabilities: {},
      },
    });
  });

  test("creates an ACP session update notification for streamed text", () => {
    expect(createACPSessionUpdate("session-1", {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "hello" },
    })).toEqual({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: "session-1",
        update: {
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "hello" },
        },
      },
    });
  });

  test("decodes unknown ACP notifications without dropping their raw update", () => {
    const message = decodeACPMessage(JSON.stringify({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: "session-1",
        update: { sessionUpdate: "future_update", value: 42 },
      },
    }));

    expect(message).toMatchObject({
      kind: "session_update",
      sessionId: "session-1",
      updateType: "future_update",
    });
    expect(message.kind === "session_update" ? message.rawUpdate : undefined).toEqual({
      sessionUpdate: "future_update",
      value: 42,
    });
  });

  test("advertises ACP v1 session capabilities and granular PiWork extensions", () => {
    expect(createACPInitializeResult({
      hostVersion: "0.1.0",
    })).toEqual({
      protocolVersion: 1,
      agentInfo: { name: "pi-work-agent-host", version: "0.1.0" },
      agentCapabilities: {
        promptCapabilities: { image: true, audio: false, embeddedContext: false },
        mcpCapabilities: { http: false, sse: false },
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
          capabilities: [
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
          ],
        },
      },
    });
  });

  test("adapts local session results to ACP v1 without exposing storage paths", () => {
    const session = {
      id: "session-1",
      path: "/private/sessions/session-1.jsonl",
      cwd: "/tmp/project",
      title: "Session one",
      firstMessage: "hello",
      messageCount: 2,
      createdAt: "2026-08-28T07:00:00Z",
      modifiedAt: "2026-08-28T08:00:00Z",
    };

    expect(adaptLegacyResultToACP("session/new", { session })).toEqual({
      sessionId: "session-1",
    });
    expect(adaptLegacyResultToACP("session/list", { sessions: [session] })).toEqual({
      sessions: [{
        sessionId: "session-1",
        cwd: "/tmp/project",
        title: "Session one",
        updatedAt: "2026-08-28T08:00:00Z",
      }],
    });
  });

  test("maps ACP permission responses back to the local access decision", () => {
    expect(permissionDecisionFromACPResponse({
      jsonrpc: "2.0",
      id: "permission-1",
      result: { outcome: { outcome: "selected", optionId: "allow-once" } },
    })).toBe("allowOnce");
    expect(permissionDecisionFromACPResponse({
      jsonrpc: "2.0",
      id: "permission-2",
      result: { outcome: { outcome: "cancelled" } },
    })).toBe("deny");
  });

  test("describes model, thinking, and boolean settings as ACP config options", () => {
    const options = createACPSessionConfigOptions({
      model: { provider: "openai", id: "gpt-test", name: "GPT Test" },
      thinkingLevel: "high",
      availableThinkingLevels: ["off", "high"],
      modelOptions: {
        fastMode: { supported: true, enabled: false },
        oneMillionContext: { supported: false, enabled: false },
      },
    }, [
      { provider: "openai", id: "gpt-test", name: "GPT Test" },
      { provider: "anthropic", id: "claude-test", name: "Claude Test" },
    ]);

    expect(options).toEqual([
      {
        id: "model",
        name: "Model",
        category: "model",
        type: "select",
        currentValue: "openai/gpt-test",
        options: [
          { value: "openai/gpt-test", name: "GPT Test" },
          { value: "anthropic/claude-test", name: "Claude Test" },
        ],
      },
      {
        id: "thought_level",
        name: "Thinking level",
        category: "thought_level",
        type: "select",
        currentValue: "high",
        options: [
          { value: "off", name: "off" },
          { value: "high", name: "high" },
        ],
      },
      {
        id: "fast_mode",
        name: "Fast mode",
        category: "model_config",
        type: "boolean",
        currentValue: false,
      },
    ]);
    expect(decodeACPModelValue("anthropic/claude/test")).toEqual({
      provider: "anthropic",
      modelId: "claude/test",
    });
  });

  test("preserves baseline ACP resource links in the prompt passed to Pi", () => {
    expect(normalizeACPPromptContent([
      { type: "text", text: "Review this" },
      {
        type: "resource_link",
        name: "Design notes",
        uri: "file:///tmp/design.md",
      },
    ])).toEqual({
      text: "Review this\n\n[Design notes](file:///tmp/design.md)",
      images: [],
    });
  });
});
