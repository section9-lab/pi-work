import { expect, test } from "bun:test";
import { ToolProgressCoalescer } from "../src/tool-progress.ts";

test("progress bursts retain only each tool's latest update in latest-event order", () => {
  const received: string[] = [];
  const progress = new ToolProgressCoalescer<string>((value) => received.push(value));
  progress.update("a", "a1"); progress.update("b", "b1"); progress.update("a", "a2");
  expect(received).toEqual([]);
  progress.flush();
  expect(received).toEqual(["b1", "a2"]);
  progress.flush();
  expect(received).toEqual(["b1", "a2"]);
  progress.dispose();
});

test("a fixed publication window flushes progress without requiring a quiet stream", async () => {
  const received: number[] = [];
  const progress = new ToolProgressCoalescer<number>((value) => received.push(value), 5);
  try {
    progress.update("a", 1);
    await Bun.sleep(30);
    expect(received).toEqual([1]);
    progress.update("a", 2);
    progress.dispose();
    await Bun.sleep(30);
    expect(received).toEqual([1]);
  } finally { progress.dispose(); }
});
