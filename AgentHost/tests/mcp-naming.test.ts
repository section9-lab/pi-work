import { describe, expect, test } from "bun:test";
import {
  createMcpToolName,
  isMcpToolName,
  mcpNamespace,
} from "../src/mcp-native-adapter";

// Pi 1.7 moved the MCP naming helpers from pi-coding-agent's internals into
// pi-mcp's public API. These assertions pin the names PiWork stores (saved
// server policies, session transcripts, approval prompts), so a future move
// fails here instead of silently renaming every MCP tool.
describe("MCP tool naming contract", () => {
  test("keeps the established namespace and tool name format", () => {
    expect(mcpNamespace("fixture")).toBe("mcp__fixture");
    expect(mcpNamespace("my-server")).toBe("mcp__my_server");
    expect(createMcpToolName("fixture", "read_record")).toBe("mcp__fixture__read_record");
    expect(createMcpToolName("my-server", "read.record")).toBe("mcp__my_server__read_record");
    expect(isMcpToolName("mcp__fixture__read_record")).toBe(true);
    expect(isMcpToolName("read_record")).toBe(false);
  });

  test("shortens long or colliding names deterministically within the model limit", () => {
    const longTool = "t".repeat(80);
    const shortened = createMcpToolName("fixture", longTool);
    expect(shortened.length).toBeLessThanOrEqual(64);
    expect(shortened).toMatch(/^mcp__fixture__t+_[0-9a-f]{8}$/);
    expect(createMcpToolName("fixture", longTool)).toBe(shortened);

    const collided = createMcpToolName("fixture", "read-record", () => true);
    expect(collided).not.toBe("mcp__fixture__read_record");
    expect(collided).toMatch(/_[0-9a-f]{8}$/);
    expect(collided.length).toBeLessThanOrEqual(64);
  });
});
