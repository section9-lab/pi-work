import { describe, expect, test } from "bun:test";
import { access, mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  AccessController,
  AccessPolicyError,
  activeToolsForMode,
  createPolicyControlledTools,
  type AccessApprovalRequest,
} from "../src/access-policy.ts";

describe("AccessController", () => {
  test("full access authorizes a tool without requesting approval", async () => {
    const controller = new AccessController({ cwd: "/tmp/project", mode: "full" });
    const requests: AccessApprovalRequest[] = [];
    controller.subscribe((request) => requests.push(request));

    await controller.authorize({
      toolCallId: "tool-one",
      toolName: "bash",
      input: { command: "bun test" },
    });

    expect(requests).toEqual([]);
  });

  test("read-only access authorizes a project file read", async () => {
    const project = await mkdtemp(join(tmpdir(), "pi-work-access-project-"));
    const file = join(project, "README.md");
    await writeFile(file, "hello");
    const controller = new AccessController({ cwd: project, mode: "readOnly" });

    await expect(controller.authorize({
      toolCallId: "tool-one",
      toolName: "read",
      input: { path: file },
    })).resolves.toBeUndefined();
  });

  test("read-only tools reject every supported alias of a project-external path", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-work-access-aliases-"));
    try {
      const project = join(root, "project");
      const outside = join(root, "outside.txt");
      await mkdir(project);
      await writeFile(outside, "synthetic outside content");
      const controller = new AccessController({ cwd: project, mode: "readOnly" });
      for (const toolName of ["read", "ls", "grep", "find"]) {
        for (const path of ["../outside.txt", "@../outside.txt", `@${outside}`, pathToFileURL(outside).href, "~/"]) {
          await expect(controller.authorize({
            toolCallId: "alias-check", toolName, input: { path },
          })).rejects.toMatchObject({ code: "path_outside_project" });
        }
      }
      const read = createPolicyControlledTools(project, controller).find((tool) => tool.name === "read")!;
      await expect(read.execute("outside-read", { path: "@../outside.txt" }, undefined, undefined, {} as never))
        .rejects.toMatchObject({ code: "path_outside_project" });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("authorized aliases and macOS filename fallbacks still read the intended project file", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-work-access-spelling-"));
    try {
      const project = join(root, "project");
      const other = join(root, "other");
      await mkdir(project);
      await mkdir(other);
      await writeFile(join(project, "fixture.txt"), "authorized fixture");
      await writeFile(join(other, "fixture.txt"), "wrong cwd fixture");
      await writeFile(join(project, "Screenshot 10.00\u202fAM.png.txt"), "macOS fixture");
      const controller = new AccessController({ cwd: project, mode: "readOnly" });
      const read = createPolicyControlledTools(project, controller).find((tool) => tool.name === "read")!;
      for (const path of ["fixture.txt", "@fixture.txt", pathToFileURL(join(project, "fixture.txt")).href]) {
        const result = await read.execute("inside-read", { path }, undefined, undefined, { cwd: other } as never);
        expect(result.content).toEqual([{ type: "text", text: "authorized fixture" }]);
      }
      const result = await read.execute("macOS-read", { path: "Screenshot 10.00 AM.png.txt" }, undefined, undefined, {} as never);
      expect(result.content).toEqual([{ type: "text", text: "macOS fixture" }]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("read-only access blocks mutation tools", async () => {
    const controller = new AccessController({ cwd: "/tmp/project", mode: "readOnly" });

    await expect(controller.authorize({
      toolCallId: "tool-one",
      toolName: "write",
      input: { path: "notes.md", content: "private" },
    })).rejects.toMatchObject({
      code: "access_denied",
      message: "write is unavailable in read-only mode",
    });
  });

  test("read-only access blocks a symlink that escapes the project", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-work-access-root-"));
    const project = join(root, "project");
    const outside = join(root, "outside");
    await mkdir(project);
    await mkdir(outside);
    await writeFile(join(outside, "secret.txt"), "secret");
    await symlink(outside, join(project, "linked"));
    const controller = new AccessController({ cwd: project, mode: "readOnly" });

    await expect(controller.authorize({
      toolCallId: "tool-one",
      toolName: "read",
      input: { path: "linked/secret.txt" },
    })).rejects.toMatchObject({
      code: "path_outside_project",
    });
  });

  test("ask mode waits for an allow-once decision", async () => {
    const controller = new AccessController({
      cwd: "/tmp/project",
      mode: "ask",
      makeRequestId: () => "approval-one",
    });
    const requests: AccessApprovalRequest[] = [];
    controller.subscribe((request) => requests.push(request));

    const authorization = controller.authorize({
      toolCallId: "tool-one",
      toolName: "bash",
      input: { command: "bun test" },
    });
    await Bun.sleep(0);

    expect(requests).toEqual([{
      id: "approval-one",
      toolCallId: "tool-one",
      toolName: "bash",
      summary: "bun test",
    }]);
    expect(controller.pendingApprovals()).toEqual(requests);

    controller.resolve("approval-one", "allowOnce");
    await expect(authorization).resolves.toBeUndefined();
    expect(controller.pendingApprovals()).toEqual([]);
  });

  test("ask mode rejects a denied tool", async () => {
    const controller = new AccessController({
      cwd: "/tmp/project",
      mode: "ask",
      makeRequestId: () => "approval-one",
    });

    const authorization = controller.authorize({
      toolCallId: "tool-one",
      toolName: "write",
      input: { path: "notes.md", content: "private" },
    });
    await Bun.sleep(0);
    controller.resolve("approval-one", "deny");

    await expect(authorization).rejects.toEqual(
      new AccessPolicyError("access_denied", "User denied write"),
    );
  });

  test("approval summaries do not expose file content", async () => {
    const controller = new AccessController({
      cwd: "/tmp/project",
      mode: "ask",
      makeRequestId: () => "approval-one",
    });
    const requests: AccessApprovalRequest[] = [];
    controller.subscribe((request) => requests.push(request));

    const authorization = controller.authorize({
      toolCallId: "tool-one",
      toolName: "write",
      input: { path: "notes.md", content: "do-not-leak" },
    });
    await Bun.sleep(0);

    expect(requests[0]?.summary).toBe("notes.md");
    expect(JSON.stringify(requests)).not.toContain("do-not-leak");
    controller.resolve("approval-one", "deny");
    await expect(authorization).rejects.toBeInstanceOf(AccessPolicyError);
  });

  test("changing to full access authorizes subsequent tools immediately", async () => {
    const controller = new AccessController({ cwd: "/tmp/project", mode: "readOnly" });

    controller.setMode("full");

    await expect(controller.authorize({
      toolCallId: "tool-one",
      toolName: "bash",
      input: { command: "bun test" },
    })).resolves.toBeUndefined();
    expect(controller.mode).toBe("full");
  });

  test("changing to full access releases approvals that are already waiting", async () => {
    const controller = new AccessController({
      cwd: "/tmp/project",
      mode: "ask",
      makeRequestId: () => "approval-one",
    });
    const authorization = controller.authorize({
      toolCallId: "tool-one",
      toolName: "bash",
      input: { command: "bun test" },
    });
    await Bun.sleep(0);

    controller.setMode("full");

    await expect(authorization).resolves.toBeUndefined();
    expect(controller.pendingApprovals()).toEqual([]);
  });

  test("changing to a stricter mode rejects approvals that are already waiting", async () => {
    const controller = new AccessController({
      cwd: "/tmp/project",
      mode: "ask",
      makeRequestId: () => "approval-one",
    });
    const authorization = controller.authorize({
      toolCallId: "tool-one",
      toolName: "write",
      input: { path: "notes.md", content: "private" },
    });
    await Bun.sleep(0);

    controller.setMode("readOnly");

    await expect(authorization).rejects.toMatchObject({ code: "access_denied" });
    expect(controller.pendingApprovals()).toEqual([]);
  });

  test("active tools match each access mode", () => {
    expect(activeToolsForMode("none")).toEqual([]);
    expect(activeToolsForMode("readOnly")).toEqual(["read", "grep", "find", "ls"]);
    expect(activeToolsForMode("ask")).toEqual(["read", "bash", "edit", "write"]);
    expect(activeToolsForMode("full")).toEqual(["read", "bash", "edit", "write"]);
  });

  test("an approved write delegates to the Pi tool", async () => {
    const project = await mkdtemp(join(tmpdir(), "pi-work-access-write-"));
    const controller = new AccessController({
      cwd: project,
      mode: "ask",
      makeRequestId: () => "approval-one",
    });
    const writeTool = createPolicyControlledTools(project, controller)
      .find((tool) => tool.name === "write");
    if (!writeTool) throw new Error("Expected a write tool");
    const destination = join(project, "approved.txt");

    const execution = writeTool.execute(
      "tool-one",
      { path: destination, content: "approved" },
      undefined,
      undefined,
      {} as never,
    );
    await Bun.sleep(0);
    controller.resolve("approval-one", "allowOnce");
    await execution;

    expect(await readFile(destination, "utf8")).toBe("approved");
  });

  test("a denied write never reaches the Pi tool", async () => {
    const project = await mkdtemp(join(tmpdir(), "pi-work-access-denied-"));
    const controller = new AccessController({
      cwd: project,
      mode: "ask",
      makeRequestId: () => "approval-one",
    });
    const writeTool = createPolicyControlledTools(project, controller)
      .find((tool) => tool.name === "write");
    if (!writeTool) throw new Error("Expected a write tool");
    const destination = join(project, "denied.txt");

    const execution = writeTool.execute(
      "tool-one",
      { path: destination, content: "denied" },
      undefined,
      undefined,
      {} as never,
    );
    await Bun.sleep(0);
    controller.resolve("approval-one", "deny");

    await expect(execution).rejects.toBeInstanceOf(AccessPolicyError);
    await expect(access(destination)).rejects.toBeDefined();
  });
});
