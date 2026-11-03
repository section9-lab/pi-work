/** Latest-value progress only. Text deltas, approvals and final events never enter this buffer. */
export class ToolProgressCoalescer<T> {
  private readonly pending = new Map<string, T>();
  private timer?: ReturnType<typeof setTimeout>;
  private disposed = false;

  constructor(private readonly publish: (value: T) => void, private readonly intervalMs = 50) {}

  update(toolCallId: string, value: T): void {
    if (this.disposed) return;
    this.pending.delete(toolCallId);
    this.pending.set(toolCallId, value);
    // Throttle, not debounce: sustained output cannot postpone publication.
    this.timer ??= setTimeout(() => this.flush(), this.intervalMs);
  }

  flush(): void {
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
    const values = [...this.pending.values()];
    this.pending.clear();
    for (const value of values) this.publish(value);
  }

  dispose(): void {
    this.disposed = true;
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
    this.pending.clear();
  }
}
