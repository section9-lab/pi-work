import { describe, expect, test } from "bun:test";
import {
  SessionManager,
  SettingsManager,
  type AgentSession,
  type AgentSessionEvent,
} from "@earendil-works/pi-coding-agent";
import type { ImageContent } from "@earendil-works/pi-ai";

import {
  PiSessionHandle,
  createPiSessionHandle,
  normalizeAgentMessages,
  normalizeAgentSessionEvent,
} from "../src/pi-session-handle.ts";
import { AccessController } from "../src/access-policy.ts";
import {
  SessionRegistryError,
  type SessionHandleEvent,
} from "../src/session-registry.ts";

const testModel = {
  id: "gpt-test",
  name: "GPT Test",
  api: "openai-responses" as const,
  provider: "openai",
  baseUrl: "https://example.com",
  reasoning: true,
  input: ["text", "image"] as ("text" | "image")[],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 128_000,
  maxTokens: 16_384,
};

const configurableModel = {
  ...testModel,
  id: "gpt-5.6-sol",
  name: "GPT-5.6 Sol",
  cost: {
    ...testModel.cost,
    tiers: [{
      inputTokensAbove: 272_000,
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
    }],
  },
  contextWindow: 272_000,
  maxTokens: 128_000,
};

type PiThinkingLevel = AgentSession["thinkingLevel"];

function makePiSession(overrides: Record<string, unknown> = {}) {
  return {
    sessionId: "session-one",
    messages: [],
    model: testModel,
    getContextUsage: () => undefined,
    getAllTools: () => [],
    thinkingLevel: "high" as PiThinkingLevel,
    getAvailableThinkingLevels: (): PiThinkingLevel[] => ["off", "low", "medium", "high", "max"],
    setThinkingLevel: (_level: PiThinkingLevel) => {},
    agent: {
      streamFunction: () => undefined as never,
    },
    modelRuntime: {
      getModel: (provider: string, modelId: string) => (
        provider === testModel.provider && modelId === testModel.id ? testModel : undefined
      ),
    },
    extensionRunner: {
      getRegisteredCommands: () => [],
    } as unknown as AgentSession["extensionRunner"],
    bindExtensions: async () => {},
    resourceLoader: {
      getSkills: () => ({ skills: [], diagnostics: [] }),
    } as unknown as AgentSession["resourceLoader"],
    setModel: async (_model: NonNullable<AgentSession["model"]>) => {},
    setActiveToolsByName: () => {},
    prompt: async () => {},
    abort: async () => {},
    reload: async () => {},
    exportToHtml: async (outputPath: string) => outputPath,
    dispose: () => {},
    subscribe: () => () => {},
    ...overrides,
  };
}

describe("normalizeAgentSessionEvent", () => {
  test("marks the start of each assistant generation", () => {
    const event = {
      type: "message_start",
      message: { role: "assistant" },
    } as unknown as AgentSessionEvent;

    expect(normalizeAgentSessionEvent(event)).toEqual({
      type: "assistantMessageStarted",
    });
  });

  test("maps Pi text deltas with their content position", () => {
    const event = {
      type: "message_update",
      assistantMessageEvent: {
        type: "text_delta",
        contentIndex: 0,
        delta: "Hello",
      },
    } as unknown as AgentSessionEvent;

    expect(normalizeAgentSessionEvent(event)).toEqual({
      type: "assistantContent",
      phase: "delta",
      contentType: "text",
      contentIndex: 0,
      delta: "Hello",
    });
  });

  test("streams provider-visible Pi thinking without exposing signatures", () => {
    const started = {
      type: "message_update",
      assistantMessageEvent: {
        type: "thinking_start",
        contentIndex: 2,
      },
    } as unknown as AgentSessionEvent;
    const delta = {
      type: "message_update",
      assistantMessageEvent: {
        type: "thinking_delta",
        contentIndex: 2,
        delta: "Checking ",
        partial: {
          content: [{
            type: "thinking",
            thinking: "Checking ",
            thinkingSignature: "secret-signature",
          }],
        },
      },
    } as unknown as AgentSessionEvent;
    const completed = {
      type: "message_update",
      assistantMessageEvent: {
        type: "thinking_end",
        contentIndex: 2,
        content: "Checking APIs",
        partial: {
          content: [{
            type: "thinking",
            thinking: "Checking APIs",
            thinkingSignature: "secret-signature",
          }],
        },
      },
    } as unknown as AgentSessionEvent;

    expect(normalizeAgentSessionEvent(started)).toEqual({
      type: "assistantContent",
      phase: "start",
      contentType: "thinking",
      contentIndex: 2,
    });
    expect(normalizeAgentSessionEvent(delta)).toEqual({
      type: "assistantContent",
      phase: "delta",
      contentType: "thinking",
      contentIndex: 2,
      delta: "Checking ",
    });
    expect(normalizeAgentSessionEvent(completed)).toEqual({
      type: "assistantContent",
      phase: "end",
      contentType: "thinking",
      contentIndex: 2,
      content: "Checking APIs",
    });
    expect(JSON.stringify(normalizeAgentSessionEvent(completed))).not.toContain("secret-signature");
  });

  test("maps Pi tool calls with their content position", () => {
    const toolCall = {
      type: "toolCall",
      id: "tool-one",
      name: "read",
      arguments: { path: "README.md" },
    };
    const started = {
      type: "message_update",
      assistantMessageEvent: {
        type: "toolcall_start",
        contentIndex: 3,
        partial: { content: [null, null, null, toolCall] },
      },
    } as unknown as AgentSessionEvent;
    const completed = {
      type: "message_update",
      assistantMessageEvent: {
        type: "toolcall_end",
        contentIndex: 3,
        toolCall,
      },
    } as unknown as AgentSessionEvent;
    const expectedToolCall = {
      id: "tool-one",
      name: "read",
      argumentsSummary: '{"path":"README.md"}',
    };

    expect(normalizeAgentSessionEvent(started)).toEqual({
      type: "assistantContent",
      phase: "start",
      contentType: "toolCall",
      contentIndex: 3,
      toolCall: expectedToolCall,
    });
    expect(normalizeAgentSessionEvent(completed)).toEqual({
      type: "assistantContent",
      phase: "end",
      contentType: "toolCall",
      contentIndex: 3,
      toolCall: expectedToolCall,
    });
  });

  test("maps Pi tool starts with ACP raw input", () => {
    const event = {
      type: "tool_execution_start",
      toolCallId: "tool-one",
      toolName: "read",
      args: { path: "README.md" },
    } as AgentSessionEvent;

    expect(normalizeAgentSessionEvent(event)).toEqual({
      type: "toolStarted",
      toolCallId: "tool-one",
      toolName: "read",
      summary: '{"path":"README.md"}',
      rawInput: { path: "README.md" },
    });
  });

  test("maps Pi tool progress to ACP content and raw output", () => {
    const event = {
      type: "tool_execution_update",
      toolCallId: "tool-one",
      toolName: "read",
      args: { path: "README.md" },
      partialResult: {
        content: [
          { type: "text", text: "\u001b[32mFirst line\u001b[0m" },
          { type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" },
        ],
        details: {
          mode: "parallel",
          results: [{ agent: "reviewer", task: "Review", exitCode: -1 }],
        },
      },
    } as AgentSessionEvent;

    expect(normalizeAgentSessionEvent(event)).toEqual({
      type: "toolUpdated",
      toolCallId: "tool-one",
      toolName: "read",
      output: "First line\n[image · image/png]",
      content: [
        { type: "text", text: "First line" },
        { type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" },
      ],
      rawOutput: {
        mode: "parallel",
        results: [{ agent: "reviewer", task: "Review", exitCode: -1 }],
      },
    });
  });

  test("maps Pi tool completion to the stable host event", () => {
    const event = {
      type: "tool_execution_end",
      toolCallId: "tool-one",
      toolName: "read",
      result: {
        content: [{ type: "text", text: "README contents" }],
        details: { bytes: 15 },
      },
      isError: false,
    } as AgentSessionEvent;

    expect(normalizeAgentSessionEvent(event)).toEqual({
      type: "toolCompleted",
      toolCallId: "tool-one",
      toolName: "read",
      output: "README contents",
      content: [{ type: "text", text: "README contents" }],
      rawOutput: { bytes: 15 },
      isError: false,
    });
  });
});

describe("PiSessionHandle", () => {
  test("delegates HTML export to the native Pi session", async () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const requests: string[] = [];
    const handle = new PiSessionHandle(makePiSession({
      exportToHtml: async (outputPath: string) => {
        requests.push(outputPath);
        return outputPath;
      },
    }), manager);

    await expect(handle.exportHtml("/tmp/report.html")).resolves.toBe("/tmp/report.html");
    expect(requests).toEqual(["/tmp/report.html"]);
  });

  test("lists invokable extension and skill slash commands from the live Pi session", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      extensionRunner: {
        getRegisteredCommands: () => [{
          invocationName: "review",
          description: "Review the current changes",
        }],
      },
      resourceLoader: {
        getSkills: () => ({
          skills: [{
            name: "ego-browser",
            description: "Browse and interact with websites",
          }],
          diagnostics: [],
        }),
      },
    });
    const handle = new PiSessionHandle(piSession as never, manager);

    expect(handle.commands()).toEqual([
      {
        name: "review",
        description: "Review the current changes",
        source: "extension",
      },
      {
        name: "skill:ego-browser",
        description: "Browse and interact with websites",
        source: "skill",
      },
    ]);
  });

  test("normalizes provider-visible thinking without leaking signatures or redacted content", () => {
    const messages = normalizeAgentMessages("session-one", [
      {
        role: "user",
        content: [
          { type: "text", text: "Inspect this" },
        ],
        timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
      },
      {
        role: "assistant",
        content: [
          {
            type: "thinking",
            thinking: "provider-visible reasoning",
            thinkingSignature: "secret-signature",
          },
          {
            type: "thinking",
            thinking: "redacted reasoning",
            thinkingSignature: "redacted-signature",
            redacted: true,
          },
          { type: "text", text: "I can help." },
          { type: "toolCall", id: "tool-one", name: "read", arguments: { path: "README.md" } },
        ],
        api: "openai-responses",
        provider: "openai",
        model: "gpt-test",
        usage: {
          input: 1,
          output: 1,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 2,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "toolUse",
        timestamp: Date.parse("2026-08-09T00:00:01.000Z"),
      },
      {
        role: "custom",
        customType: "private-context",
        content: "Do not display",
        display: false,
        timestamp: Date.parse("2026-08-09T00:00:02.000Z"),
      },
    ] as never[]);

    expect(messages).toEqual([
      {
        id: "session-one:1786233600000:0",
        role: "user",
        content: [
          { type: "text", text: "Inspect this" },
        ],
        timestamp: "2026-08-09T00:00:00.000Z",
      },
      {
        id: "session-one:1786233601000:1",
        role: "assistant",
        content: [
          {
            type: "thinking",
            thinking: "provider-visible reasoning",
            redacted: false,
          },
          { type: "thinking", thinking: "", redacted: true },
          { type: "text", text: "I can help." },
          {
            type: "toolCall",
            id: "tool-one",
            name: "read",
            argumentsSummary: '{"path":"README.md"}',
          },
        ],
        timestamp: "2026-08-09T00:00:01.000Z",
        provider: "openai",
        model: "gpt-test",
        stopReason: "toolUse",
      },
    ]);
    expect(JSON.stringify(messages)).toContain("provider-visible reasoning");
    expect(JSON.stringify(messages)).not.toContain("redacted reasoning");
    expect(JSON.stringify(messages)).not.toContain("secret-signature");
    expect(JSON.stringify(messages)).not.toContain("redacted-signature");
    expect(JSON.stringify(messages)).not.toContain("Do not display");
  });

  test("preserves user image data for local transcript previews", () => {
    const data = "iVBORw0KGgo=";
    const messages = normalizeAgentMessages("session-one", [{
      role: "user",
      content: [{ type: "image", data, mimeType: "image/png" }],
      timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
    }] as never[]);

    expect(messages[0]?.content).toEqual([{
      type: "image",
      mimeType: "image/png",
      data,
    }]);
  });

  test("records an injected skill without exposing its instructions or path", () => {
    const messages = normalizeAgentMessages("session-one", [{
      role: "user",
      content: [{
        type: "text",
        text: [
          '<skill name="ego-browser" location="/tmp/ego-browser/SKILL.md">',
          "# ego-browser",
          "Internal instructions that must not appear in the transcript.",
          "</skill>",
          "",
          "使用这个再试试呢",
        ].join("\n"),
      }],
      timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
    }] as never[]);

    expect(messages[0]?.content).toEqual([
      {
        type: "skill",
        name: "ego-browser",
      },
      {
        type: "text",
        text: "使用这个再试试呢",
      },
    ]);
    expect(JSON.stringify(messages)).not.toContain("Internal instructions");
    expect(JSON.stringify(messages)).not.toContain("SKILL.md");
    expect(JSON.stringify(messages)).not.toContain("/tmp/ego-browser");
  });

  test("hides injected skill instructions even when the skill name is missing", () => {
    const messages = normalizeAgentMessages("session-one", [{
      role: "user",
      content: [{
        type: "text",
        text: [
          '<skill location="/tmp/unknown/SKILL.md">',
          "Internal instructions that must not appear in the transcript.",
          "</skill>",
          "",
          "继续",
        ].join("\n"),
      }],
      timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
    }] as never[]);

    expect(messages[0]?.content).toEqual([{ type: "text", text: "继续" }]);
    expect(JSON.stringify(messages)).not.toContain("Internal instructions");
    expect(JSON.stringify(messages)).not.toContain("SKILL.md");
  });

  test("strips terminal formatting from persisted tool output", () => {
    const messages = normalizeAgentMessages("session-one", [{
      role: "toolResult",
      toolCallId: "tool-one",
      toolName: "bash",
      content: [{ type: "text", text: "\u001b[31mfailed\u001b[0m" }],
      isError: true,
      timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
    }] as never[]);

    expect(messages[0]?.content).toEqual([{ type: "text", text: "failed" }]);
  });

  test("snapshots preview large tool output and loads the full output on demand", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const fullOutput = "0123456789".repeat(10_000);
    const piSession = makePiSession({
      messages: [{
        role: "toolResult",
        toolCallId: "tool-one",
        toolName: "bash",
        content: [{ type: "text", text: fullOutput }],
        isError: false,
        timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
      }],
    });
    const handle = new PiSessionHandle(piSession as never, manager);

    const message = handle.snapshot().messages[0];

    expect(message?.toolOutputTruncated).toBe(true);
    expect(JSON.stringify(message).length).toBeLessThan(20_000);
    expect(handle.toolOutput("tool-one")).toBe(fullOutput);
  });

  test("snapshots omit large inline tool images", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      messages: [{
        role: "toolResult",
        toolCallId: "tool-image",
        toolName: "read",
        content: [{ type: "image", mimeType: "image/png", data: "a".repeat(100_000) }],
        isError: false,
        timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
      }],
    });
    const handle = new PiSessionHandle(piSession as never, manager);

    const message = handle.snapshot().messages[0];

    expect(message?.toolOutputTruncated).toBe(true);
    expect(message?.content).toEqual([{ type: "text", text: "[image: image/png]" }]);
    expect(JSON.stringify(message).length).toBeLessThan(2_000);
    expect(handle.toolOutput("tool-image")).toBe("[image: image/png]");
  });

  test("snapshots return only the most recent transcript page", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      messages: Array.from({ length: 85 }, (_, index) => ({
        role: "user" as const,
        content: `Message ${index}`,
        timestamp: Date.parse("2026-08-09T00:00:00.000Z") + index,
      })),
    });
    const handle = new PiSessionHandle(piSession as never, manager);

    const snapshot = handle.snapshot({ messageLimit: 40 });

    expect(snapshot.messages).toHaveLength(40);
    expect(snapshot.messages[0]?.content).toEqual([{ type: "text", text: "Message 45" }]);
    expect(snapshot.messages.at(-1)?.content).toEqual([{ type: "text", text: "Message 84" }]);
    expect(snapshot.history).toEqual({
      revision: expect.any(String),
      nextCursor: expect.any(String),
      hasMore: true,
    });
  });

  test("loads earlier transcript pages without overlap", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      messages: Array.from({ length: 85 }, (_, index) => ({
        role: "user" as const,
        content: `Message ${index}`,
        timestamp: Date.parse("2026-08-09T00:00:00.000Z") + index,
      })),
    });
    const handle = new PiSessionHandle(piSession as never, manager);
    const snapshot = handle.snapshot({ messageLimit: 40 });
    const history = snapshot.history;
    if (!history?.nextCursor) throw new Error("Expected a history cursor");

    const previous = handle.transcriptPage(history.nextCursor, 40);

    expect(previous.messages).toHaveLength(40);
    expect(previous.messages[0]?.content).toEqual([{ type: "text", text: "Message 5" }]);
    expect(previous.messages.at(-1)?.content).toEqual([{ type: "text", text: "Message 44" }]);
    expect(previous.hasMore).toBe(true);
    expect(previous.nextCursor).toEqual(expect.any(String));
    expect(previous.revision).toBe(history.revision);

    const finalPage = handle.transcriptPage(previous.nextCursor!, 40);
    expect(finalPage.messages).toHaveLength(5);
    expect(finalPage.messages[0]?.content).toEqual([{ type: "text", text: "Message 0" }]);
    expect(finalPage.hasMore).toBe(false);
    expect(finalPage.nextCursor).toBeNull();
  });

  test("keeps a tool call and its results in the same transcript page", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      messages: [
        {
          role: "user",
          content: "Inspect the repository",
          timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
        },
        {
          role: "assistant",
          content: [{
            type: "toolCall",
            id: "tool-one",
            name: "read",
            arguments: { path: "README.md" },
          }],
          provider: "openai",
          model: "gpt-test",
          stopReason: "toolUse",
          timestamp: Date.parse("2026-08-09T00:00:01.000Z"),
        },
        {
          role: "toolResult",
          toolCallId: "tool-one",
          toolName: "read",
          content: [{ type: "text", text: "Repository contents" }],
          isError: false,
          timestamp: Date.parse("2026-08-09T00:00:02.000Z"),
        },
      ],
    });
    const handle = new PiSessionHandle(piSession as never, manager);

    const snapshot = handle.snapshot({ messageLimit: 1 });

    expect(snapshot.messages.map((message) => message.role)).toEqual(["assistant", "tool"]);
    expect(snapshot.history?.hasMore).toBe(true);
  });

  test("rejects a transcript cursor after the session reloads", async () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      messages: Array.from({ length: 2 }, (_, index) => ({
        role: "user" as const,
        content: `Message ${index}`,
        timestamp: Date.parse("2026-08-09T00:00:00.000Z") + index,
      })),
    });
    const handle = new PiSessionHandle(piSession as never, manager);
    const cursor = handle.snapshot({ messageLimit: 1 }).history?.nextCursor;
    if (!cursor) throw new Error("Expected a history cursor");

    await handle.reload();

    expect(() => handle.transcriptPage(cursor, 1)).toThrow("History cursor is stale");
  });

  test("rejects a transcript cursor after the message boundary changes", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const messages = Array.from({ length: 3 }, (_, index) => ({
      role: "user" as const,
      content: `Message ${index}`,
      timestamp: Date.parse("2026-08-09T00:00:00.000Z") + index,
    }));
    const piSession = makePiSession({ messages });
    const handle = new PiSessionHandle(piSession as never, manager);
    const cursor = handle.snapshot({ messageLimit: 1 }).history?.nextCursor;
    if (!cursor) throw new Error("Expected a history cursor");

    messages.shift();

    expect(() => handle.transcriptPage(cursor, 1)).toThrow("History cursor is stale");
  });

  test("skips hidden custom messages while building transcript pages", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const firstTimestamp = Date.parse("2026-08-09T00:00:00.000Z");
    const piSession = makePiSession({
      messages: [
        { role: "user", content: "Earlier", timestamp: firstTimestamp },
        ...Array.from({ length: 5 }, (_, index) => ({
          role: "custom" as const,
          content: `Internal ${index}`,
          display: false,
          timestamp: firstTimestamp + index + 1,
        })),
        { role: "user", content: "Latest", timestamp: firstTimestamp + 6 },
      ],
    });
    const handle = new PiSessionHandle(piSession as never, manager);
    const cursor = handle.snapshot({ messageLimit: 1 }).history?.nextCursor;
    if (!cursor) throw new Error("Expected a history cursor");

    const page = handle.transcriptPage(cursor, 1);

    expect(page.messages).toHaveLength(1);
    expect(page.messages[0]?.content).toEqual([{ type: "text", text: "Earlier" }]);
    expect(page.hasMore).toBe(false);
  });

  test("builds a normalized snapshot from the live Pi session", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    manager.appendMessage({
      role: "user",
      content: "Resume this work",
      timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
    });
    manager.appendSessionInfo("Session integration");
    const piSession = makePiSession({
      sessionId: manager.getSessionId(),
      messages: manager.buildSessionContext().messages,
    });
    const handle = new PiSessionHandle(piSession, manager);

    expect(handle.snapshot()).toEqual({
      session: {
        id: manager.getSessionId(),
        path: "",
        cwd: "/tmp/project",
        title: "Session integration",
      },
      messages: [{
        id: `${manager.getSessionId()}:1786233600000:0`,
        role: "user",
        content: [{ type: "text", text: "Resume this work" }],
        timestamp: "2026-08-09T00:00:00.000Z",
      }],
      model: {
        provider: "openai",
        id: "gpt-test",
        name: "GPT Test",
        contextWindow: 128_000,
        maxTokens: 16_384,
        reasoning: true,
        supportsImages: true,
        supportsFastMode: false,
      },
      accessMode: "full",
      thinkingLevel: "high",
      availableThinkingLevels: ["off", "low", "medium", "high", "max"],
      modelOptions: {
        fastMode: { supported: false, enabled: false },
        oneMillionContext: { supported: false, enabled: false },
      },
      pendingApprovals: [],
    });
  });

  test("persists the selected Git branch in the session snapshot", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const handle = new PiSessionHandle(makePiSession(), manager);

    expect(handle.setGitBranch("feature/session-picker")).toBe("feature/session-picker");
    expect(handle.snapshot().gitBranch).toBe("feature/session-picker");

    const reopened = new PiSessionHandle(makePiSession(), manager);
    expect(reopened.snapshot().gitBranch).toBe("feature/session-picker");
  });

  test("rejects changing the selected Git branch after the conversation starts", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const handle = new PiSessionHandle(
      makePiSession({
        messages: [{
          role: "user",
          content: "Start coding",
          timestamp: Date.parse("2026-08-09T00:00:00.000Z"),
        }],
      }),
      manager,
    );

    expect(() => handle.setGitBranch("feature/other")).toThrow(
      "Git branch can only be selected before the conversation starts",
    );
  });

  test("derives Fast and 1M context support from the active Pi model", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const handle = new PiSessionHandle(
      makePiSession({ model: configurableModel }),
      manager,
    );

    expect(handle.snapshot().modelOptions).toEqual({
      fastMode: { supported: true, enabled: false },
      oneMillionContext: { supported: true, enabled: false },
    });
  });

  test("keeps custom proxy models disabled when capabilities are not declared by Pi", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const proxiedModel = {
      ...configurableModel,
      provider: "cc-switch-openai",
      api: "openai-completions" as const,
    };
    const handle = new PiSessionHandle(
      makePiSession({ model: proxiedModel }),
      manager,
    );

    expect(handle.snapshot().modelOptions).toEqual({
      fastMode: { supported: false, enabled: false },
      oneMillionContext: { supported: false, enabled: false },
    });
  });

  test("injects Pi's priority service tier only while Fast mode is enabled", async () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const receivedOptions: Array<Record<string, unknown> | undefined> = [];
    const agent = {
      streamFunction: (
        _model: unknown,
        _context: unknown,
        options?: Record<string, unknown>,
      ) => {
        receivedOptions.push(options);
        return undefined as never;
      },
    };
    const piSession = makePiSession({ model: configurableModel, agent });
    const handle = new PiSessionHandle(piSession, manager);

    await handle.setModelOption("fastMode", true);
    agent.streamFunction(configurableModel, {}, {});
    await handle.setModelOption("fastMode", false);
    agent.streamFunction(configurableModel, {}, {});

    expect(receivedOptions).toEqual([
      { serviceTier: "priority" },
      { serviceTier: "default" },
    ]);
  });

  test("changes Pi's effective context window when 1M context is toggled", async () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const selectedContextWindows: number[] = [];
    const piSession = makePiSession({ model: configurableModel });
    piSession.setModel = async (model: NonNullable<AgentSession["model"]>) => {
      selectedContextWindows.push(model.contextWindow);
      piSession.model = model;
    };
    const handle = new PiSessionHandle(piSession, manager);

    const enabled = await handle.setModelOption("oneMillionContext", true);
    const disabled = await handle.setModelOption("oneMillionContext", false);

    expect(selectedContextWindows).toEqual([1_050_000, 272_000]);
    expect(enabled.modelOptions.oneMillionContext).toEqual({ supported: true, enabled: true });
    expect(disabled.modelOptions.oneMillionContext).toEqual({ supported: true, enabled: false });
  });

  test("rejects enabling a model option that the selected model does not support", async () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const handle = new PiSessionHandle(makePiSession(), manager);

    expect(handle.setModelOption("fastMode", true)).rejects.toMatchObject({
      code: "model_option_unsupported",
    });
  });

  test("exposes Pi's current context usage in the normalized snapshot", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const contextUsage = {
      tokens: 96_000,
      contextWindow: 128_000,
      percent: 75,
    };
    const handle = new PiSessionHandle(
      makePiSession({ getContextUsage: () => contextUsage }),
      manager,
    );

    expect(handle.snapshot().contextUsage).toEqual(contextUsage);
  });

  test("persists a renamed title through SessionManager", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const handle = new PiSessionHandle(makePiSession(), manager);

    expect(handle.rename("Session integration")).toBe("Session integration");
    expect(manager.getSessionName()).toBe("Session integration");
  });

  test("resolves and delegates model selection to Pi", async () => {
    const manager = SessionManager.inMemory("/tmp/project");
    let selectedModel: unknown;
    const handle = new PiSessionHandle(makePiSession({
      setModel: async (model: unknown) => { selectedModel = model; },
    }), manager);

    const result = await handle.setModel("openai", "gpt-test");

    expect(selectedModel).toBe(testModel);
    expect(result).toEqual({
      provider: "openai",
      id: "gpt-test",
      name: "GPT Test",
      contextWindow: 128_000,
      maxTokens: 16_384,
      reasoning: true,
      supportsImages: true,
      supportsFastMode: false,
    });
  });

  test("returns Pi's effective thinking level after selection", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    let selectedLevel: string | undefined;
    const piSession = makePiSession();
    piSession.thinkingLevel = "low";
    piSession.setThinkingLevel = (level: PiThinkingLevel) => {
      selectedLevel = level;
      piSession.thinkingLevel = "high";
    };
    piSession.getAvailableThinkingLevels = (): PiThinkingLevel[] => ["off", "low", "high"];
    const handle = new PiSessionHandle(piSession, manager);

    const result = handle.setThinkingLevel("max");

    expect(selectedLevel).toBe("max");
    expect(result).toEqual({
      thinkingLevel: "high",
      availableThinkingLevels: ["off", "low", "high"],
    });
  });

  test("returns a stable error when Pi rejects an otherwise known model", async () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const handle = new PiSessionHandle(makePiSession({
      setModel: async () => { throw new Error("Authentication required"); },
    }), manager);

    try {
      await handle.setModel("openai", "gpt-test");
      throw new Error("Expected model selection to fail");
    } catch (error) {
      expect(error).toBeInstanceOf(SessionRegistryError);
      expect(error).toMatchObject({
        code: "model_unavailable",
        message: "Authentication required",
      });
    }
  });

  test("subscribers receive only normalized Pi events", () => {
    let piListener: ((event: AgentSessionEvent) => void) | undefined;
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      subscribe: (listener: (event: AgentSessionEvent) => void) => {
        piListener = listener;
        return () => { piListener = undefined; };
      },
    });
    const handle = new PiSessionHandle(piSession, manager);
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    piListener?.({ type: "agent_start" } as AgentSessionEvent);
    piListener?.({
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "Hello" },
    } as AgentSessionEvent);

    expect(events).toEqual([{
      type: "assistantContent",
      phase: "delta",
      contentType: "text",
      contentIndex: 0,
      delta: "Hello",
    }]);
  });

  test("delegates prompts to the Pi session", async () => {
    let receivedPrompt: string | undefined;
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      prompt: async (text: string) => { receivedPrompt = text; },
    });
    const handle = new PiSessionHandle(piSession, manager);

    await handle.prompt("Build the feature");

    expect(receivedPrompt).toBe("Build the feature");
  });

  test("delegates prompt images as Pi prompt options", async () => {
    let receivedImages: ImageContent[] | undefined;
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      prompt: async (_text: string, options?: { images?: ImageContent[] }) => {
        receivedImages = options?.images;
      },
    });
    const handle = new PiSessionHandle(piSession, manager);
    const image: ImageContent = {
      type: "image",
      mimeType: "image/png",
      data: "iVBORw0KGgo=",
    };

    await handle.prompt("Inspect this", [image]);

    expect(receivedImages).toEqual([image]);
  });

  test("rejects a resolved prompt when Pi finishes with an assistant error", async () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const messages: AgentSession["messages"] = [];
    const piSession = makePiSession({
      messages,
      prompt: async () => {
        messages.push({
          role: "assistant",
          content: [],
          api: "openai-responses",
          provider: "github-copilot",
          model: "gpt-5.6-terra",
          usage: {
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 0,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
          },
          stopReason: "error",
          errorMessage: "OAuth module unavailable",
          timestamp: Date.now(),
        });
      },
    });
    const handle = new PiSessionHandle(piSession, manager);

    expect(handle.prompt("Hello")).rejects.toThrow("OAuth module unavailable");
  });

  test("delegates abort to the Pi session", async () => {
    let abortCount = 0;
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      abort: async () => { abortCount += 1; },
    });
    const handle = new PiSessionHandle(piSession, manager);

    await handle.abort();

    expect(abortCount).toBe(1);
  });

  test("reloads Pi resources and activates newly loaded extension tools", async () => {
    const manager = SessionManager.inMemory("/tmp/project");
    let tools = [{
      name: "old_extension_tool",
      sourceInfo: { source: "npm:old-extension" },
    }];
    const activeToolSelections: string[][] = [];
    const piSession = makePiSession({
      getAllTools: () => tools,
      reload: async () => {
        tools = [{
          name: "new_extension_tool",
          sourceInfo: { source: "npm:new-extension" },
        }];
      },
      setActiveToolsByName: (names: string[]) => activeToolSelections.push(names),
    });
    const accessController = new AccessController({ cwd: "/tmp/project", mode: "ask" });
    const handle = new PiSessionHandle(
      piSession,
      manager,
      accessController,
      [],
      "all",
    );

    await handle.reload();

    expect(activeToolSelections.at(-1)).toEqual([
      "read", "bash", "edit", "write", "new_extension_tool",
    ]);
  });

  test("delegates disposal to the Pi session", () => {
    let disposeCount = 0;
    const manager = SessionManager.inMemory("/tmp/project");
    const piSession = makePiSession({
      dispose: () => { disposeCount += 1; },
    });
    const handle = new PiSessionHandle(piSession, manager);

    handle.dispose();

    expect(disposeCount).toBe(1);
  });

  test("changes active Pi tools when access mode changes", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const activeToolSelections: string[][] = [];
    const piSession = makePiSession({
      setActiveToolsByName: (names: string[]) => activeToolSelections.push(names),
    });
    const accessController = new AccessController({ cwd: "/tmp/project", mode: "ask" });
    const handle = new PiSessionHandle(piSession, manager, accessController);

    expect(handle.setAccessMode("readOnly")).toBe("readOnly");
    expect(activeToolSelections).toEqual([["read", "grep", "find", "ls"]]);
    expect(handle.snapshot().accessMode).toBe("readOnly");
  });
});

describe("createPiSessionHandle", () => {
  test("binds Pi extension dialogs to the standard ACP UI context", async () => {
    const manager = SessionManager.inMemory("/tmp/pi-work-project");
    let bindings: Parameters<AgentSession["bindExtensions"]>[0] | undefined;
    const piSession = makePiSession({
      sessionId: manager.getSessionId(),
      bindExtensions: async (value: Parameters<AgentSession["bindExtensions"]>[0]) => {
        bindings = value;
      },
    });

    await createPiSessionHandle(
      {
        sessionManager: manager,
        profile: "work",
        requestElicitation: async () => ({
          action: "accept",
          content: { value: "Continue" },
        }),
      },
      async () => ({ session: piSession }),
    );

    expect(bindings?.mode).toBe("rpc");
    expect(await bindings?.uiContext?.select("Action", ["Continue", "Stop"]))
      .toBe("Continue");
  });

  test("replays extension widgets and status emitted while extensions bind", async () => {
    const manager = SessionManager.inMemory("/tmp/pi-work-project");
    const piSession = makePiSession({
      sessionId: manager.getSessionId(),
      bindExtensions: async (value: Parameters<AgentSession["bindExtensions"]>[0]) => {
        value.uiContext?.setWidget("any-checklist-widget", ["☑ Inspect", "☐ Implement"]);
        value.uiContext?.setStatus("status-demo", "Ready");
      },
    });

    const handle = await createPiSessionHandle(
      {
        sessionManager: manager,
        profile: "work",
        requestElicitation: async () => ({ action: "cancel" }),
      },
      async () => ({ session: piSession }),
    );
    const events: SessionHandleEvent[] = [];

    handle.subscribe((event) => events.push(event));

    expect(events).toEqual([
      { type: "extensionStatusChanged", key: "status-demo", text: "Ready" },
      {
        type: "extensionWidgetChanged",
        key: "any-checklist-widget",
        widget: { lines: ["☑ Inspect", "☐ Implement"], placement: "aboveEditor" },
      },
    ]);
    expect(handle.snapshot().extensionStatuses).toEqual({
      "status-demo": "Ready",
    });
    expect(handle.snapshot()).toMatchObject({
      extensionWidgets: {
        "any-checklist-widget": { lines: ["☑ Inspect", "☐ Implement"], placement: "aboveEditor" },
      },
    });
    expect(handle.snapshot().plan).toBeUndefined();
  });

  test("clears old extension UI before publishing reloaded widgets", async () => {
    const manager = SessionManager.inMemory("/tmp/pi-work-project");
    let disposals = 0;
    let ui: Parameters<AgentSession["bindExtensions"]>[0]["uiContext"];
    const piSession = makePiSession({
      sessionId: manager.getSessionId(),
      bindExtensions: async (bindings: Parameters<AgentSession["bindExtensions"]>[0]) => {
        ui = bindings.uiContext;
        ui?.setWidget("old-plugin", () => ({
          render: () => ["Running"],
          invalidate() {},
          dispose() { disposals += 1; },
        }));
        ui?.setStatus("old-plugin", "Ready");
      },
      reload: async (options?: Parameters<AgentSession["reload"]>[0]) => {
        ui?.setStatus("old-plugin", "Shutting down");
        await options?.beforeSessionStart?.();
        ui?.setWidget("new-plugin", () => ({
          render: () => ["Reloaded"],
          invalidate() {},
          dispose() { disposals += 1; },
        }));
      },
    });
    const handle = await createPiSessionHandle({
      sessionManager: manager,
      profile: "work",
      requestElicitation: async () => ({ action: "cancel" }),
    }, async () => ({ session: piSession }));
    const events: SessionHandleEvent[] = [];
    handle.subscribe((event) => events.push(event));
    events.length = 0;

    await handle.reload();

    expect(disposals).toBe(1);
    expect(handle.snapshot().extensionWidgets).toEqual({
      "new-plugin": { lines: ["Reloaded"], placement: "aboveEditor" },
    });
    expect(handle.snapshot().extensionStatuses ?? {}).toEqual({});
    expect(events).toContainEqual({ type: "extensionWidgetChanged", key: "old-plugin" });
    expect(events).toContainEqual({ type: "extensionStatusChanged", key: "old-plugin" });
    handle.dispose();
    expect(disposals).toBe(2);
  });

  async function injectedSystemPrompt(
    profile: "chat" | "work",
    manager: SessionManager,
  ): Promise<string> {
    let receivedOptions: Parameters<typeof createPiSessionHandle>[0] & {
      resourceLoader?: AgentSession["resourceLoader"];
    } | undefined;

    await createPiSessionHandle(
      {
        sessionManager: manager,
        profile,
        agentDir: "/tmp/pi-work-context-agent",
        settingsManager: SettingsManager.inMemory(),
        now: () => new Date("2026-08-10T16:30:00.000Z"),
        timeZone: "Asia/Shanghai",
      },
      async (options) => {
        receivedOptions = options as typeof receivedOptions;
        return { session: makePiSession({ sessionId: manager.getSessionId() }) };
      },
    );

    const resourceLoader = receivedOptions?.resourceLoader;
    expect(resourceLoader).toBeDefined();
    if (!resourceLoader) return "";

    const extension = resourceLoader.getExtensions().extensions.find(
      (candidate) => candidate.path === "<inline:pi-work-context>",
    );
    expect(extension).toBeDefined();
    const handler = extension?.handlers.get("before_agent_start")?.[0];
    expect(handler).toBeDefined();
    if (!handler) return "";

    const result = await handler({
      type: "before_agent_start",
      prompt: "Hello",
      images: undefined,
      systemPrompt: "Base instructions",
      systemPromptOptions: {},
    }, {});
    return (result as { systemPrompt?: string } | undefined)?.systemPrompt ?? "";
  }

  test("adds the minimal Chat context through Pi's extension API", async () => {
    const manager = SessionManager.inMemory("/tmp/pi-work-chat");

    const systemPrompt = await injectedSystemPrompt("chat", manager);

    expect(systemPrompt).toBe([
      "Base instructions",
      "",
      "<pi_work_context>",
      "profile: chat",
      "current_date: 2026-08-11",
      "timezone: Asia/Shanghai",
      "purpose: General conversation and web research.",
      "</pi_work_context>",
    ].join("\n"));
  });

  test("adds the minimal Work context and selected Git branch through Pi's extension API", async () => {
    const manager = SessionManager.inMemory("/tmp/pi-work-project");
    manager.appendCustomEntry("pi-work.git-branch", { branch: "feature/session-picker" });

    const systemPrompt = await injectedSystemPrompt("work", manager);

    expect(systemPrompt).toContain("profile: work");
    expect(systemPrompt).toContain("current_date: 2026-08-11");
    expect(systemPrompt).toContain("timezone: Asia/Shanghai");
    expect(systemPrompt).toContain("purpose: Coding and project work.");
    expect(systemPrompt).toContain("feature/session-picker");
    expect(systemPrompt).toContain("target Git branch");
  });

  test("injects pi-work's isolated settings into each Pi session", async () => {
    const manager = SessionManager.inMemory("/tmp/pi-work-chat");
    const settingsManager = SettingsManager.inMemory({ retry: { enabled: false } });
    let receivedOptions: Record<string, unknown> | undefined;

    await createPiSessionHandle(
      {
        sessionManager: manager,
        profile: "chat",
        agentDir: "/tmp/pi-work-agent",
        settingsManager,
      },
      async (options) => {
        receivedOptions = options as unknown as Record<string, unknown>;
        return { session: makePiSession({ sessionId: manager.getSessionId() }) };
      },
    );

    expect(receivedOptions?.agentDir).toBe("/tmp/pi-work-agent");
    expect(receivedOptions?.settingsManager).toBe(settingsManager);
  });

  test("activates pi-web-access tools without built-in tools for a Chat session", async () => {
    const manager = SessionManager.inMemory("/tmp/pi-work-chat");
    let receivedOptions: Record<string, unknown> | undefined;
    const activeToolSelections: string[][] = [];
    const piSession = makePiSession({
      sessionId: manager.getSessionId(),
      getAllTools: () => [
        {
          name: "web_search",
          sourceInfo: { source: "npm:pi-web-access" },
        },
        {
          name: "fetch_content",
          sourceInfo: { source: "npm:pi-web-access" },
        },
        {
          name: "other_extension_tool",
          sourceInfo: { source: "npm:other-extension" },
        },
      ],
      setActiveToolsByName: (names: string[]) => activeToolSelections.push(names),
    });

    const handle = await createPiSessionHandle(
      { sessionManager: manager, profile: "chat" },
      async (options) => {
        receivedOptions = options as unknown as Record<string, unknown>;
        return { session: piSession };
      },
    );

    expect(handle.sessionId).toBe(manager.getSessionId());
    expect(receivedOptions?.cwd).toBe("/tmp/pi-work-chat");
    expect(receivedOptions?.sessionManager).toBe(manager);
    expect(receivedOptions?.noTools).toBeUndefined();
    expect(receivedOptions?.tools).toBeUndefined();
    expect(receivedOptions?.excludeTools).toEqual([
      "read", "bash", "edit", "write", "grep", "find", "ls",
    ]);
    expect(receivedOptions?.customTools).toBeUndefined();
    expect(activeToolSelections).toEqual([["web_search", "fetch_content"]]);
    expect(handle.snapshot().accessMode).toBe("none");
  });

  test("installs policy-controlled tools and extension tools for a Work session", async () => {
    const manager = SessionManager.inMemory("/tmp/pi-work-project");
    let receivedOptions: Record<string, unknown> | undefined;
    const activeToolSelections: string[][] = [];
    const piSession = makePiSession({
      sessionId: manager.getSessionId(),
      getAllTools: () => [{
        name: "web_search",
        sourceInfo: { source: "npm:pi-web-access" },
      }, {
        name: "extension_tool",
        sourceInfo: { source: "npm:example-extension" },
      }],
      setActiveToolsByName: (names: string[]) => activeToolSelections.push(names),
    });

    const handle = await createPiSessionHandle(
      { sessionManager: manager, profile: "work" },
      async (options) => {
        receivedOptions = options as unknown as Record<string, unknown>;
        return { session: piSession };
      },
    );

    expect(receivedOptions?.noTools).toBeUndefined();
    expect(receivedOptions?.tools).toBeUndefined();
    expect(receivedOptions?.customTools).toHaveLength(7);
    expect(activeToolSelections).toEqual([[
      "read", "bash", "edit", "write", "web_search", "extension_tool",
    ]]);
    expect(handle.snapshot().accessMode).toBe("full");
    expect(handle.snapshot().pendingApprovals).toEqual([]);

    handle.setAccessMode("readOnly");
    expect(activeToolSelections.at(-1)).toEqual([
      "read", "grep", "find", "ls", "web_search", "extension_tool",
    ]);
  });
});
