import { describe, expect, test } from "bun:test";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  AgentSettingsCoordinator,
  createAgentSettingsCoordinator,
  createAgentSettingsManager,
} from "../src/agent-settings.ts";

describe("AgentSettingsCoordinator", () => {
  test("returns the effective desktop-agent defaults", () => {
    const coordinator = new AgentSettingsCoordinator(SettingsManager.inMemory());

    expect(coordinator.snapshot()).toEqual({
      defaultModel: null,
      defaultThinkingLevel: "off",
      transport: "auto",
      compactionEnabled: true,
      retryEnabled: true,
    });
  });

  test("persists supported settings through Pi's SettingsManager", async () => {
    const settings = SettingsManager.inMemory();
    const coordinator = new AgentSettingsCoordinator(settings);

    await coordinator.update({
      defaultModel: { provider: "openai", modelId: "gpt-test" },
      defaultThinkingLevel: "high",
      transport: "sse",
      compactionEnabled: false,
      retryEnabled: false,
    });

    expect(coordinator.snapshot()).toEqual({
      defaultModel: { provider: "openai", modelId: "gpt-test" },
      defaultThinkingLevel: "high",
      transport: "sse",
      compactionEnabled: false,
      retryEnabled: false,
    });
  });

  test("writes desktop settings into the configured agent directory", async () => {
    const directory = await mkdtemp(join(tmpdir(), "pi-work-agent-settings-"));
    try {
      const coordinator = createAgentSettingsCoordinator(
        directory,
        { PI_WORK_AGENT_DIR: directory },
      );

      await coordinator.update({ retryEnabled: false });

      expect(JSON.parse(await readFile(join(directory, "settings.json"), "utf8"))).toEqual({
        retry: { enabled: false },
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("uses bundled Bun without writing its path into the shared settings", async () => {
    const directory = await mkdtemp(join(tmpdir(), "pi-work-agent-bun-settings-"));
    const bunPath = join(directory, "Portable Apps", "PiWork.app", "Contents/Helpers/Bun/arm64/bun");
    try {
      const settings = createAgentSettingsManager(
        directory,
        {
          PI_WORK_AGENT_DIR: directory,
          PI_WORK_BUN_PATH: bunPath,
        },
      );

      await settings.flush();

      expect(settings.getNpmCommand()).toEqual([
        bunPath,
        "--no-env-file",
        "--config=/dev/null",
        "--registry=https://registry.npmjs.org",
        "--no-cache",
      ]);
      expect(await readFile(join(directory, "settings.json"), "utf8")
        .catch((error: NodeJS.ErrnoException) => error.code)).toBe("ENOENT");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("keeps the terminal package manager unchanged after edits and reloads", async () => {
    const directory = await mkdtemp(join(tmpdir(), "pi-work-agent-bun-migration-"));
    const bunPath = join(directory, "PiWork.app", "Contents/Helpers/Bun/arm64/bun");
    try {
      const previous = SettingsManager.create(directory, directory);
      previous.setNpmCommand(["npm", "--registry=https://example.test"]);
      previous.setPackages(["npm:example-extension@1.2.3"]);
      await previous.flush();

      const settings = createAgentSettingsManager(directory, {
        PI_WORK_AGENT_DIR: directory,
        PI_WORK_BUN_PATH: bunPath,
      });
      await new AgentSettingsCoordinator(settings).update({ retryEnabled: false });
      await settings.reload();

      expect(settings.getNpmCommand()).toEqual([
        bunPath, "--no-env-file", "--config=/dev/null",
        "--registry=https://registry.npmjs.org", "--no-cache",
      ]);
      expect(JSON.parse(await readFile(join(directory, "settings.json"), "utf8")))
        .toMatchObject({
          npmCommand: ["npm", "--registry=https://example.test"],
          packages: ["npm:example-extension@1.2.3"],
          retry: { enabled: false },
        });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("refreshes the bundled Bun command after the app moves", async () => {
    const directory = await mkdtemp(join(tmpdir(), "pi-work-agent-bun-relocated-"));
    try {
      for (const location of ["original", "移动后的 App"]) {
        const bunPath = join(directory, location, "PiWork.app", "Contents/Helpers/Bun/arm64/bun");
        const settings = createAgentSettingsManager(directory, {
          PI_WORK_AGENT_DIR: directory,
          PI_WORK_BUN_PATH: bunPath,
        });
        await settings.flush();

        expect(settings.getNpmCommand()).toEqual([
          bunPath, "--no-env-file", "--config=/dev/null",
          "--registry=https://registry.npmjs.org", "--no-cache",
        ]);
        expect(await readFile(join(directory, "settings.json"), "utf8")
          .catch((error: NodeJS.ErrnoException) => error.code)).toBe("ENOENT");
      }
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
});
