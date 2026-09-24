import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { TuiMainScreen, stripTerminalSequences, type Component } from "@earendil-works/pi-tui";
import type { ACPRequest, ACPResponse } from "./acp-protocol.ts";
import type { SessionExtensionWidget } from "./session-registry.ts";

type ElicitationProperty =
  | {
      type: "string";
      title?: string;
      description?: string;
      default?: string;
      oneOf?: Array<{ const: string; title: string }>;
    }
  | {
      type: "boolean";
      title?: string;
      default?: boolean;
    };

export type ACPElicitationRequest = {
  mode: "form";
  sessionId: string;
  message: string;
  requestedSchema: {
    type: "object";
    properties: Record<string, ElicitationProperty>;
    required: string[];
  };
};

export type ACPElicitationResponse =
  | { action: "accept"; content?: Record<string, unknown> | null }
  | { action: "decline" }
  | { action: "cancel" };

export type ACPElicitationRequester = (
  request: ACPElicitationRequest,
) => Promise<ACPElicitationResponse>;

export type ACPExtensionUICallbacks = {
  onStatusChanged?: (key: string, text: string | undefined) => void;
  onWidgetChanged?: (key: string, widget: SessionExtensionWidget | undefined) => void;
};

export type ACPExtensionUIContext = ExtensionUIContext & { clearWidgets(): void };

// Reuse Pi's render scheduling without opening stdin or writing to the ACP stream.
class HeadlessWidgetTUI extends TuiMainScreen {
  constructor(private readonly publish: () => void) {
    super({
      columns: 80,
      rows: 24,
      kittyProtocolActive: false,
      start() {},
      stop() {},
      async drainInput() {},
      write() {},
      moveBy() {},
      hideCursor() {},
      showCursor() {},
      clearLine() {},
      clearFromCursor() {},
      clearScreen() {},
      setTitle() {},
      setProgress() {},
    });
  }

  protected override doRender(): void {
    if (!this.stopped) this.publish();
  }
}

const headlessTheme = {
  fg: (_color: string, value: string) => value,
  bg: (_color: string, value: string) => value,
  bold: (value: string) => value,
  italic: (value: string) => value,
  underline: (value: string) => value,
  inverse: (value: string) => value,
  strikethrough: (value: string) => value,
  getFgAnsi: () => "",
  getBgAnsi: () => "",
  getColorMode: () => "truecolor" as const,
  getThinkingBorderColor: () => (value: string) => value,
  getBashModeBorderColor: () => (value: string) => value,
} as unknown as ExtensionUIContext["theme"];

export class ACPElicitationBroker {
  private readonly pending = new Map<string, {
    resolve: (response: ACPElicitationResponse) => void;
    reject: (error: Error) => void;
  }>();

  constructor(private readonly send: (request: ACPRequest) => void) {}

  request = (params: ACPElicitationRequest): Promise<ACPElicitationResponse> => {
    const id = `elicitation-${crypto.randomUUID()}`;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.send({ jsonrpc: "2.0", id, method: "elicitation/create", params });
    });
  };

  resolve(response: ACPResponse): boolean {
    const id = response.id === null ? "" : String(response.id);
    const pending = this.pending.get(id);
    if (!pending) return false;
    this.pending.delete(id);
    if (response.error) {
      pending.reject(new Error(response.error.message));
      return true;
    }
    const result = response.result as ACPElicitationResponse | undefined;
    if (!result || !["accept", "decline", "cancel"].includes(result.action)) {
      pending.reject(new Error("Invalid ACP elicitation response"));
      return true;
    }
    pending.resolve(result);
    return true;
  }
}

export function createACPExtensionUIContext(
  sessionId: string,
  requestElicitation: ACPElicitationRequester,
  callbacks: ACPExtensionUICallbacks = {},
): ACPExtensionUIContext {
  const widgetDisposers = new Map<string, () => void>();
  const stringElicitation = async (
    title: string,
    property: ElicitationProperty,
  ): Promise<string | undefined> => {
    const response = await requestElicitation({
      mode: "form",
      sessionId,
      message: title,
      requestedSchema: {
        type: "object",
        properties: { value: property },
        required: ["value"],
      },
    });
    const value = response.action === "accept" ? response.content?.value : undefined;
    return typeof value === "string" ? value : undefined;
  };

  return {
    select(title, options) {
      return stringElicitation(title, {
        type: "string",
        title,
        oneOf: options.map((option) => ({ const: option, title: option })),
      });
    },
    async confirm(title, message) {
      const response = await requestElicitation({
        mode: "form",
        sessionId,
        message: title,
        requestedSchema: {
          type: "object",
          properties: {
            confirmed: {
              type: "boolean",
              title: message,
              default: false,
            },
          },
          required: ["confirmed"],
        },
      });
      return response.action === "accept" && response.content?.confirmed === true;
    },
    input(title, placeholder) {
      return stringElicitation(title, {
        type: "string",
        title,
        ...(placeholder ? { description: placeholder } : {}),
      });
    },
    editor(title, prefill) {
      return stringElicitation(title, {
        type: "string",
        title,
        ...(prefill === undefined ? {} : { default: prefill }),
      });
    },
    notify() {},
    onTerminalInput() { return () => {}; },
    setStatus(key, text) {
      callbacks.onStatusChanged?.(key, text === undefined ? undefined : stripTerminalSequences(text));
    },
    setWorkingMessage() {},
    setWorkingVisible() {},
    setWorkingIndicator() {},
    setHiddenThinkingLabel() {},
    setWidget(key, content, options) {
      widgetDisposers.get(key)?.();
      widgetDisposers.delete(key);
      const placement = options?.placement ?? "aboveEditor";
      let previousLines: string[] | undefined;
      const publish = (output: string[]) => {
        const lines = output.map(stripTerminalSequences);
        if (previousLines?.length === lines.length
          && lines.every((line, index) => line === previousLines![index])) return;
        previousLines = lines;
        callbacks.onWidgetChanged?.(key, { lines, placement });
      };
      if (Array.isArray(content)) {
        publish(content);
      } else if (content === undefined) {
        callbacks.onWidgetChanged?.(key, undefined);
      } else {
        let component: (Component & { dispose?(): void }) | undefined;
        const renderFailure = (error: unknown) => publish([
          `Widget rendering failed: ${error instanceof Error ? error.message : String(error)}`,
        ]);
        const tui = new HeadlessWidgetTUI(() => {
          try {
            if (component) publish(component.render(tui.terminal.columns));
          } catch (error) {
            renderFailure(error);
          }
        });
        widgetDisposers.set(key, () => {
          tui.stop();
          try {
            component?.dispose?.();
          } catch (error) {
            console.error(`Widget ${key} disposal failed:`, error);
          }
        });
        try {
          component = content(tui, headlessTheme);
          tui.addChild(component);
          tui.renderNow();
        } catch (error) {
          renderFailure(error);
        }
      }
    },
    clearWidgets() {
      for (const dispose of widgetDisposers.values()) dispose();
      widgetDisposers.clear();
    },
    setFooter() {},
    setHeader() {},
    setTitle() {},
    async custom<T>() { return undefined as T; },
    pasteToEditor() {},
    setEditorText() {},
    getEditorText() { return ""; },
    addAutocompleteProvider() {},
    setEditorComponent() {},
    getEditorComponent() { return undefined; },
    theme: headlessTheme,
    getAllThemes() { return []; },
    getTheme() { return undefined; },
    setTheme() {
      return { success: false, error: "Theme switching is unavailable over ACP" };
    },
    getToolsExpanded() { return false; },
    setToolsExpanded() {},
  };
}
