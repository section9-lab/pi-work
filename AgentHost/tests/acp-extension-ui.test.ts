import { describe, expect, test } from "bun:test";

import {
  ACPElicitationBroker,
  createACPExtensionUIContext,
  type ACPElicitationRequest,
} from "../src/acp-extension-ui.ts";

describe("ACP extension UI bridge", () => {
  test("correlates standard ACP elicitation responses by JSON-RPC request ID", async () => {
    const messages: unknown[] = [];
    const broker = new ACPElicitationBroker((message) => messages.push(message));
    const request: ACPElicitationRequest = {
      mode: "form",
      sessionId: "session-one",
      message: "Name",
      requestedSchema: {
        type: "object",
        properties: { value: { type: "string", title: "Name" } },
        required: ["value"],
      },
    };

    const response = broker.request(request);
    const requestId = (messages[0] as { id: string }).id;

    expect(messages).toEqual([{
      jsonrpc: "2.0",
      id: requestId,
      method: "elicitation/create",
      params: request,
    }]);
    expect(broker.resolve({
      jsonrpc: "2.0",
      id: requestId,
      result: { action: "accept", content: { value: "Ada" } },
    })).toBe(true);
    expect(await response).toEqual({ action: "accept", content: { value: "Ada" } });
  });

  test("maps Pi select dialogs to a standard ACP elicitation form", async () => {
    const requests: ACPElicitationRequest[] = [];
    const ui = createACPExtensionUIContext("session-one", async (request) => {
      requests.push(request);
      return { action: "accept", content: { value: "Run tests" } };
    });

    const result = await ui.select("Next action", ["Run tests", "Cancel"]);

    expect(result).toBe("Run tests");
    expect(requests).toEqual([{
      mode: "form",
      sessionId: "session-one",
      message: "Next action",
      requestedSchema: {
        type: "object",
        properties: {
          value: {
            type: "string",
            title: "Next action",
            oneOf: [
              { const: "Run tests", title: "Run tests" },
              { const: "Cancel", title: "Cancel" },
            ],
          },
        },
        required: ["value"],
      },
    }]);
  });

  test("maps Pi confirmation dialogs to a standard boolean elicitation", async () => {
    const requests: ACPElicitationRequest[] = [];
    const ui = createACPExtensionUIContext("session-one", async (request) => {
      requests.push(request);
      return { action: "accept", content: { confirmed: true } };
    });

    const result = await ui.confirm("Delete files?", "This cannot be undone");

    expect(result).toBe(true);
    expect(requests).toEqual([{
      mode: "form",
      sessionId: "session-one",
      message: "Delete files?",
      requestedSchema: {
        type: "object",
        properties: {
          confirmed: {
            type: "boolean",
            title: "This cannot be undone",
            default: false,
          },
        },
        required: ["confirmed"],
      },
    }]);
  });

  test("maps Pi single-line and editor input to standard string elicitations", async () => {
    const requests: ACPElicitationRequest[] = [];
    const responses = [
      { action: "accept" as const, content: { value: "Ada" } },
      { action: "accept" as const, content: { value: "Line 1\nLine 2" } },
    ];
    const ui = createACPExtensionUIContext("session-one", async (request) => {
      requests.push(request);
      return responses.shift()!;
    });

    expect(await ui.input("Name", "Enter your name")).toBe("Ada");
    expect(await ui.editor("Edit note", "Initial text")).toBe("Line 1\nLine 2");
    expect(requests).toEqual([
      {
        mode: "form",
        sessionId: "session-one",
        message: "Name",
        requestedSchema: {
          type: "object",
          properties: {
            value: {
              type: "string",
              title: "Name",
              description: "Enter your name",
            },
          },
          required: ["value"],
        },
      },
      {
        mode: "form",
        sessionId: "session-one",
        message: "Edit note",
        requestedSchema: {
          type: "object",
          properties: {
            value: {
              type: "string",
              title: "Edit note",
              default: "Initial text",
            },
          },
          required: ["value"],
        },
      },
    ]);
  });

  test("degrades TUI-only UI without emitting a private protocol", async () => {
    let requestCount = 0;
    const ui = createACPExtensionUIContext("session-one", async () => {
      requestCount += 1;
      return { action: "cancel" };
    });

    ui.notify("done");
    ui.setStatus("example", "running");
    ui.setWidget("example", ["line"]);
    ui.setEditorText("draft");
    expect(await ui.custom(async () => ({ render: () => [], invalidate: () => {} } as never)))
      .toBeUndefined();
    expect(requestCount).toBe(0);
  });

  test("provides a headless theme for extensions that format status text", () => {
    const ui = createACPExtensionUIContext("session-one", async () => ({ action: "cancel" }));

    expect(ui.theme.fg("accent", ui.theme.bold("Ready"))).toBe("Ready");
  });

  test("preserves widget text without inferring an ACP plan", () => {
    const plans: unknown[] = [];
    const widgets: unknown[] = [];
    const callbacks = {
      onPlanChanged: (entries: unknown) => plans.push(entries),
      onStatusChanged: () => {},
      onWidgetChanged: (key: string, widget: unknown) => widgets.push({ key, widget }),
    };
    const ui = createACPExtensionUIContext(
      "session-one",
      async () => ({ action: "cancel" }),
      callbacks,
    );
    const lines = [
      "Plan Progress",
      "✓ Inspect current rendering",
      "○ Bridge plugin state",
      "○ Verify Swift UI",
    ];

    ui.setWidget("any-plugin-widget", lines);

    expect(widgets).toEqual([{
      key: "any-plugin-widget",
      widget: { lines, placement: "aboveEditor" },
    }]);
    expect(plans).toEqual([]);
    ui.setWidget("any-plugin-widget", undefined);
    expect(widgets.at(-1)).toEqual({ key: "any-plugin-widget", widget: undefined });
  });

  test("keeps independent plain-text widgets and their placement", () => {
    const widgets: unknown[] = [];
    const callbacks = {
      onStatusChanged: () => {},
      onWidgetChanged: (key: string, widget: unknown) => widgets.push({ key, widget }),
    };
    const ui = createACPExtensionUIContext("session-one", async () => ({ action: "cancel" }), callbacks);
    const lines = ["Build running", "Elapsed: 12s"];

    ui.setWidget("alpha", lines, { placement: "belowEditor" });
    lines[0] = "mutated after publication";
    ui.setWidget("beta", ["2 workers running"]);
    ui.setWidget("alpha", []);

    expect(widgets).toEqual([
      { key: "alpha", widget: { lines: ["Build running", "Elapsed: 12s"], placement: "belowEditor" } },
      { key: "beta", widget: { lines: ["2 workers running"], placement: "aboveEditor" } },
      { key: "alpha", widget: { lines: [], placement: "aboveEditor" } },
    ]);
  });

  test("renders component widgets and refreshes them on requestRender", async () => {
    const widgets: unknown[] = [];
    const ui = createACPExtensionUIContext("session-one", async () => ({ action: "cancel" }), {
      onWidgetChanged: (key, widget) => widgets.push({ key, widget }),
    });
    let state = "pending";
    let requestRender = () => {};
    let disposals = 0;
    ui.setWidget("any-component", (tui, theme) => {
      requestRender = () => tui.requestRender();
      return {
        render: (width) => [theme.bold(`Task: ${state}`), `Width: ${width}`],
        invalidate() {},
        dispose() { disposals += 1; },
      };
    });
    expect(widgets.at(-1)).toEqual({
      key: "any-component",
      widget: { lines: ["Task: pending", "Width: 80"], placement: "aboveEditor" },
    });
    state = "completed";
    requestRender();
    requestRender();
    await Bun.sleep(80);
    expect(widgets).toHaveLength(2);
    expect(widgets.at(-1)).toMatchObject({ widget: { lines: ["Task: completed", "Width: 80"] } });
    requestRender();
    await Bun.sleep(80);
    expect(widgets).toHaveLength(2);

    state = "stale";
    requestRender();
    ui.setWidget("any-component", undefined);
    await Bun.sleep(80);
    expect(disposals).toBe(1);
    expect(widgets).toHaveLength(3);
    expect(widgets.at(-1)).toEqual({ key: "any-component", widget: undefined });
  });

  test("isolates component render failures and removes terminal escape sequences", () => {
    const widgets: unknown[] = [];
    const statuses: unknown[] = [];
    const ui = createACPExtensionUIContext("session-one", async () => ({ action: "cancel" }), {
      onWidgetChanged: (key, widget) => widgets.push({ key, widget }),
      onStatusChanged: (key, text) => statuses.push({ key, text }),
    });
    ui.setWidget("broken", () => { throw new Error("Unsupported component"); });
    expect(widgets.at(-1)).toMatchObject({
      key: "broken", widget: { lines: ["Widget rendering failed: Unsupported component"] },
    });
    ui.setWidget("working", ["\u001b[32mReady\u001b[0m"]);
    ui.setStatus("working", "\u001b[32mReady\u001b[0m");
    expect(widgets.at(-1)).toMatchObject({ key: "working", widget: { lines: ["Ready"] } });
    expect(statuses).toEqual([{ key: "working", text: "Ready" }]);
  });

  test("disposes replaced components and all remaining widgets", () => {
    let disposals = 0;
    const ui = createACPExtensionUIContext("session-one", async () => ({ action: "cancel" }));
    const component = () => ({
      render: () => ["Ready"],
      invalidate() {},
      dispose() { disposals += 1; },
    });
    ui.setWidget("alpha", component);
    ui.setWidget("alpha", ["Replaced"]);
    expect(disposals).toBe(1);
    ui.setWidget("beta", component);
    ui.clearWidgets();
    ui.clearWidgets();
    expect(disposals).toBe(2);
  });

  test("forwards extension status through the scoped compatibility callback", () => {
    const statuses: unknown[] = [];
    const ui = createACPExtensionUIContext(
      "session-one",
      async () => ({ action: "cancel" }),
      { onStatusChanged: (key, text) => statuses.push({ key, text }) },
    );

    ui.setStatus("status-line", "Turn 2 · 1.2k tokens");
    ui.setStatus("status-line", undefined);

    expect(statuses).toEqual([
      { key: "status-line", text: "Turn 2 · 1.2k tokens" },
      { key: "status-line", text: undefined },
    ]);
  });
});
