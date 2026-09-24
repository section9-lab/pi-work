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

  test("writes desktop settings only inside pi-work's agent directory", async () => {
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

  test("configures Pi's package manager to use pi-work's bundled Bun", async () => {
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
        "--registry=https://registry.npmjs.org",
        "--no-cache",
      ]);
      expect(JSON.parse(await readFile(join(directory, "settings.json"), "utf8")))
        .toMatchObject({
          npmCommand: [
            bunPath,
            "--registry=https://registry.npmjs.org",
            "--no-cache",
          ],
        });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("upgrades an existing bundled Bun command without changing other settings", async () => {
    const directory = await mkdtemp(join(tmpdir(), "pi-work-agent-bun-migration-"));
    const bunPath = join(directory, "PiWork.app", "Contents/Helpers/Bun/arm64/bun");
    try {
      const previous = SettingsManager.create(directory, directory);
      previous.setNpmCommand([bunPath]);
      previous.setPackages(["npm:example-extension@1.2.3"]);
      await previous.flush();

      const settings = createAgentSettingsManager(directory, {
        PI_WORK_AGENT_DIR: directory,
        PI_WORK_BUN_PATH: bunPath,
      });
      await settings.flush();

      expect(JSON.parse(await readFile(join(directory, "settings.json"), "utf8")))
        .toMatchObject({
          npmCommand: [bunPath, "--registry=https://registry.npmjs.org", "--no-cache"],
          packages: ["npm:example-extension@1.2.3"],
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

        expect(JSON.parse(await readFile(join(directory, "settings.json"), "utf8")).npmCommand)
          .toEqual([bunPath, "--registry=https://registry.npmjs.org", "--no-cache"]);
      }
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
});
