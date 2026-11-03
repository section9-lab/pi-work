import { describe, expect, test } from "bun:test";
import { SessionManager, type AgentSession, type AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { PiSessionHandle } from "../src/pi-session-handle.ts";
import { SessionRegistry, type SessionHandleEvent, type SessionRegistryEvent, type QueuedInput } from "../src/session-registry.ts";

function fixture() {
  const manager = SessionManager.inMemory("/tmp/compaction-test");
  for (let i = 0; i < 85; i++) manager.appendMessage({ role: "user", content: `Message ${i}`, timestamp: 1000 + i });
  const listeners = new Set<(event: AgentSessionEvent) => void>();
  const emit = (event: AgentSessionEvent) => { for (const listener of listeners) listener(event); };
  let resolve!: () => void;
  let reject!: (error: Error) => void;
  let compactInstructions: string | undefined;
  const prompts: string[] = [];
  const runtime = {
    sessionId: manager.getSessionId(),
    get messages() { return manager.buildSessionContext().messages; },
    model: undefined,
    modelRuntime: { getModel: () => undefined },
    agent: { onPayload: undefined },
    getContextUsage: () => ({ tokens: 32000, contextWindow: 200000, percent: 16 }),
    getAvailableThinkingLevels: () => ["off"], thinkingLevel: "off",
    getAllTools: () => [], getActiveToolNames: () => [],
    subscribe: (listener: (event: AgentSessionEvent) => void) => { listeners.add(listener); return () => listeners.delete(listener); },
    compact: async (instructions?: string) => {
      compactInstructions = instructions;
      emit({ type: "compaction_start", reason: "manual" });
      try {
        await new Promise<void>((yes, no) => { resolve = yes; reject = no; });
        const id = manager.getBranch().find(entry => entry.type === "message")!.id;
        manager.appendCompaction("## Goal\nKeep the design decisions.", id, 148000);
        emit({ type: "compaction_end", reason: "manual", aborted: false, willRetry: false,
          result: { summary: "## Goal\nKeep the design decisions.", firstKeptEntryId: id,
            tokensBefore: 148000, estimatedTokensAfter: 32000 } });
      } catch (error) {
        const aborted = (error as Error).message === "cancelled";
        emit({ type: "compaction_end", reason: "manual", result: undefined, aborted,
          willRetry: false, errorMessage: aborted ? undefined : "Summary unavailable" });
        throw error;
      }
    },
    abortCompaction: () => reject(new Error("cancelled")),
    abort: async () => {},
    prompt: async (text: string, options: { preflightResult?: () => void }) => {
      prompts.push(text); options?.preflightResult?.();
    },
    clearQueue: () => {}, dispose: () => {},
  };
  const handle = new PiSessionHandle(runtime as unknown as AgentSession, manager);
  return { manager, handle, emit, prompts, succeed: () => resolve(), fail: () => reject(new Error("503")), instructions: () => compactInstructions };
}

const input = (id: string): QueuedInput => ({ id, text: `Queued ${id}`, images: [], behavior: "followUp" });

describe("compaction lifecycle and history", () => {
  test("preserves original history, stable IDs, cursor and title after repeated compactions", () => {
    const { manager, handle } = fixture();
    const before = handle.snapshot({ messageLimit: 40 });
    const first = manager.getBranch().find(entry => entry.type === "message")!;
    const kept = manager.getBranch().filter(entry => entry.type === "message")[80]!;
    const compactionId = manager.appendCompaction("Summary", kept.id, 148000);
    const after = handle.snapshot();
    expect(after.messages.filter(message => message.role === "user")).toHaveLength(85);
    expect(after.messages[0]!.id).toBe(first.id);
    expect(after.messages.find(message => message.id === compactionId)?.compaction).toMatchObject({
      id: compactionId, status: "completed", summary: "Summary", tokensBefore: 148000,
    });
    expect(after.messages.find(message => message.id === compactionId)?.compaction?.estimatedTokensAfter).toBeUndefined();
    expect(after.session.title).toBe("Message 0");
    const page = handle.transcriptPage(before.history!.nextCursor!, 40);
    expect(page.messages[0]!.content).toEqual([{ type: "text", text: "Message 5" }]);
    manager.appendCompaction("New summary", kept.id, 160000);
    expect(handle.snapshot().messages.filter(message => message.compaction)).toHaveLength(2);
    expect(handle.snapshot().messages[0]!.id).toBe(first.id);
  });

  test("system state at a compaction boundary never becomes a duplicate visible record", () => {
    const { manager, handle } = fixture();
    manager.appendMessage({ role: "system", content: "Private system instructions", timestamp: 9999 });
    const kept = manager.getBranch().find(entry => entry.type === "message")!;
    manager.appendCompaction("Summary", kept.id, 148000);
    const messages = handle.snapshot().messages;
    expect(messages.filter(message => message.compaction)).toHaveLength(1);
    expect(new Set(messages.map(message => message.id)).size).toBe(messages.length);
    expect(JSON.stringify(messages)).not.toContain("Private system instructions");
  });

  test("running snapshots and persisted completion share structured metadata without duplication", async () => {
    const f = fixture();
    const events: SessionHandleEvent[] = [];
    const unsubscribe = f.handle.subscribe(event => events.push(event));
    const task = f.handle.compact("Preserve the decisions");
    expect(f.handle.snapshot().compaction).toMatchObject({ status: "running", reason: "manual" });
    f.succeed(); await task;
    expect(f.instructions()).toBe("Preserve the decisions");
    expect(f.handle.snapshot().compaction).toBeUndefined();
    const outcome = events.filter(event => event.type === "compactionChanged").at(-1)!;
    expect(outcome.type === "compactionChanged" && outcome.compaction).toMatchObject({ status: "completed", estimatedTokensAfter: 32000 });
    const records = f.handle.snapshot().messages.filter(message => message.compaction);
    expect(records).toHaveLength(1);
    expect(records[0]!.compaction).toEqual(outcome.type === "compactionChanged" ? outcome.compaction : undefined);
    unsubscribe();
  });

  test("failed and cancelled outcomes survive subsequent snapshots", async () => {
    const f = fixture(); f.handle.subscribe(() => {});
    const task = f.handle.compact(); f.fail(); await task.catch(() => {});
    const again = f.handle.compact(); f.handle.cancelCompaction(); await again.catch(() => {});
    expect(f.handle.snapshot().messages.flatMap(message => message.compaction ? [message.compaction.status] : [])).toEqual(["failed", "cancelled"]);
    expect(f.handle.snapshot().messages.filter(message => message.compaction)[0]!.compaction?.errorMessage).toBe("Summary unavailable");
  });

  test("forwards automatic compaction without an active prompt turn", () => {
    const f = fixture(); const events: SessionRegistryEvent[] = [];
    const registry = new SessionRegistry(event => events.push(event)); registry.register(f.handle);
    f.emit({ type: "compaction_start", reason: "overflow" });
    expect(events[0]).toMatchObject({ event: "session.compactionChanged", payload: { sequence: 1, compaction: { reason: "overflow", status: "running" } } });
    expect(registry.snapshot(f.handle.sessionId).compaction?.reason).toBe("overflow");
    registry.closeAll();
  });
});

describe("manual compaction queue", () => {
  test("queues idempotently and delivers only after successful compaction", async () => {
    const f = fixture(); const events: SessionRegistryEvent[] = [];
    const registry = new SessionRegistry(event => events.push(event)); registry.register(f.handle);
    const task = registry.compact(f.handle.sessionId, "Keep goals");
    expect(registry.snapshot(f.handle.sessionId).state).toBe("running");
    await registry.enqueueInput(f.handle.sessionId, input("one"));
    await registry.enqueueInput(f.handle.sessionId, input("one"));
    expect(registry.snapshot(f.handle.sessionId).queuedInputs).toHaveLength(1);
    expect(f.prompts).toEqual([]);
    expect(() => registry.prompt(f.handle.sessionId, "another", "Parallel prompt")).toThrow();
    f.succeed(); await task;
    expect(f.prompts).toEqual(["Queued one"]);
    expect(events.filter(event => event.event === "session.inputDelivered")).toHaveLength(1);
    registry.closeAll();
  });

  for (const outcome of ["cancel", "fail"] as const) {
    test(`${outcome} recovers queued messages without sending`, async () => {
      const f = fixture(); const events: SessionRegistryEvent[] = [];
      const registry = new SessionRegistry(event => events.push(event)); registry.register(f.handle);
      const task = registry.compact(f.handle.sessionId);
      await registry.enqueueInput(f.handle.sessionId, input("one"));
      if (outcome === "cancel") registry.cancelCompaction(f.handle.sessionId); else f.fail();
      await task;
      expect(f.prompts).toEqual([]);
      expect(registry.snapshot(f.handle.sessionId).state).toBe("idle");
      expect(events.some(event => event.event === "session.inputQueueChanged" && event.payload.recoveredInputs?.[0]?.id === "one")).toBe(true);
      expect(events.some(event => event.event === "session.error")).toBe(false);
      registry.closeAll();
    });
  }
});
