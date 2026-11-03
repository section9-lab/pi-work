import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ResolvedPaths } from "@earendil-works/pi-coding-agent";

import {
  ExtensionPackagesCoordinator,
  requiredPiWebAccessRuntimeSource,
  type ExtensionPackageManager,
} from "../src/extension-packages.ts";

function resolvedPaths(
  extensions: ResolvedPaths["extensions"],
): ResolvedPaths {
  return { extensions, skills: [], prompts: [], themes: [] };
}

describe("ExtensionPackagesCoordinator", () => {
  test("listing packages never requires an installation or changes shared configuration", async () => {
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => [], resolve: async () => resolvedPaths([]),
      installAndPersist: async () => { throw new Error("Installation is unavailable offline"); },
      update: async () => {}, removeAndPersist: async () => true,
    };
    expect(await new ExtensionPackagesCoordinator(manager).list()).toEqual({ packages: [] });
  });
  test("concurrent required setup shares installation and can retry after a failure", async () => {
    const configured = new Set<string>();
    const installed: string[] = [];
    let offline = true;
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => [...configured].map((source) => ({ source, scope: "user", filtered: false })),
      resolve: async () => resolvedPaths([]),
      installAndPersist: async (source) => {
        installed.push(source);
        await Bun.sleep(10);
        if (offline) throw new Error("offline");
        configured.add(source);
      }, update: async () => {}, removeAndPersist: async () => true,
    };
    const coordinator = new ExtensionPackagesCoordinator(manager);
    const failed = await Promise.allSettled([coordinator.prepareRequired(), coordinator.prepareRequired()]);
    expect(failed.map((result) => result.status)).toEqual(["rejected", "rejected"]);
    expect(installed).toEqual([requiredPiWebAccessRuntimeSource]);
    expect(await coordinator.list()).toEqual({ packages: [] });
    offline = false;
    await Promise.all([coordinator.prepareRequired(), coordinator.prepareRequired()]);
    expect([...configured]).toEqual([requiredPiWebAccessRuntimeSource, "npm:pi-web-access"]);
    expect(installed).toEqual([requiredPiWebAccessRuntimeSource, requiredPiWebAccessRuntimeSource, "npm:pi-web-access"]);
    expect(await coordinator.prepareRequired()).toBe(false);
  });

  test("reads installed versions and refreshes them after updating", async () => {
    const directory = await mkdtemp(join(tmpdir(), "pi-work-package-version-"));
    try {
      const manifest = join(directory, "package.json");
      await writeFile(manifest, JSON.stringify({ version: "1.2.3" }));
      await writeFile(join(directory, "CHANGELOG.md"), "## [1.3.0]\nNew feature\n## [1.2.3]\nOld feature");
      const manager: ExtensionPackageManager = {
        listConfiguredPackages: () => [{
          source: "npm:pi-tools", scope: "user", filtered: false, installedPath: directory,
        }],
        resolve: async () => resolvedPaths([{
          path: join(directory, "index.ts"), enabled: true,
          metadata: { source: "npm:pi-tools", scope: "user", origin: "package" },
        }]),
        installAndPersist: async () => {},
        update: async () => { await writeFile(manifest, JSON.stringify({ version: "1.3.0" })); },
        removeAndPersist: async () => true,
      };
      const coordinator = new ExtensionPackagesCoordinator(manager);
      expect((await coordinator.list()).packages[0]).toMatchObject({ version: "1.2.3" });
      expect((await coordinator.update("npm:pi-tools")).packages[0]).toMatchObject({ version: "1.3.0", updateInfo: {
        status: "updated", fromVersion: "1.2.3", toVersion: "1.3.0", changelog: "## [1.3.0]\nNew feature",
      } });
      expect((await coordinator.update("npm:pi-tools")).packages[0]).toMatchObject({ updateInfo: {
        status: "unchanged", fromVersion: "1.3.0", toVersion: "1.3.0",
      } });

      for (const content of ["invalid JSON", "{}", '{"version":123}', '{"version":"  "}']) {
        await writeFile(manifest, content);
        expect((await coordinator.list()).packages[0]).not.toHaveProperty("version");
      }
      await rm(manifest);
      expect((await coordinator.list()).packages[0]).not.toHaveProperty("version");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("installs pi-web-access as the default extension", async () => {
    const calls: string[] = [];
    const configuredSources = new Set<string>();
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => Array.from(configuredSources).map((source) => ({
        source,
        scope: "user" as const,
        filtered: false,
        installedPath: `/tmp/${source.slice("npm:".length)}`,
      })),
      resolve: async () => resolvedPaths(configuredSources.has("npm:pi-web-access")
        ? [{
            path: "/tmp/pi-web-access/index.ts",
            enabled: true,
            metadata: {
              source: "npm:pi-web-access",
              scope: "user",
              origin: "package",
            },
          }]
        : []),
      installAndPersist: async (source) => {
        calls.push(source);
        configuredSources.add(source);
      },
      update: async () => {},
      removeAndPersist: async () => true,
    };
    const coordinator = new ExtensionPackagesCoordinator(manager);

    await coordinator.prepareRequired();
    expect(await coordinator.list()).toMatchObject({
      packages: [{ source: "npm:pi-web-access", enabled: true }],
    });
    expect(calls).toEqual([
      requiredPiWebAccessRuntimeSource,
      "npm:pi-web-access",
    ]);
  });

  test("reenables a previously filtered pi-web-access package", async () => {
    let packages: Array<string | {
      source: string;
      extensions?: string[];
      skills?: string[];
      prompts?: string[];
      themes?: string[];
    }> = [{
      source: "npm:pi-web-access",
      extensions: [],
      skills: [],
      prompts: [],
      themes: [],
    }];
    const settings = {
      getPackages: () => packages,
      setPackages: (_scope: "user" | "project", next: typeof packages) => {
        packages = next;
      },
      flush: async () => {},
    };
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => [{
        source: "npm:pi-web-access",
        scope: "user",
        filtered: typeof packages[0] === "object",
        installedPath: "/tmp/pi-web-access",
      }],
      resolve: async () => resolvedPaths([{
        path: "/tmp/pi-web-access/index.ts",
        enabled: typeof packages[0] === "string",
        metadata: {
          source: "npm:pi-web-access",
          scope: "user",
          origin: "package",
        },
      }]),
      installAndPersist: async () => {},
      update: async () => {},
      removeAndPersist: async () => true,
    };
    const coordinator = new ExtensionPackagesCoordinator(manager, settings);

    await coordinator.prepareRequired();

    expect(packages).toEqual(["npm:pi-web-access"]);
  });

  test("does not allow pi-web-access to be disabled", async () => {
    const settings = {
      getPackages: () => ["npm:pi-web-access"],
      setPackages: () => {},
      flush: async () => {},
    };
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => [],
      resolve: async () => resolvedPaths([]),
      installAndPersist: async () => {},
      update: async () => {},
      removeAndPersist: async () => true,
    };
    const coordinator = new ExtensionPackagesCoordinator(manager, settings);

    await expect(
      coordinator.setEnabled("npm:pi-web-access", "user", false),
    ).rejects.toThrow("pi-web-access is required");
  });

  test("does not allow pi-web-access to be removed", async () => {
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => [],
      resolve: async () => resolvedPaths([]),
      installAndPersist: async () => {},
      update: async () => {},
      removeAndPersist: async () => true,
    };
    const coordinator = new ExtensionPackagesCoordinator(manager);

    await expect(
      coordinator.remove("npm:pi-web-access", "user"),
    ).rejects.toThrow("pi-web-access is required");
  });

  test("lists only configured packages that expose extension resources", async () => {
    let missingSourceAction: "install" | "skip" | "error" | undefined;
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => [
        {
          source: "npm:pi-tools",
          scope: "user",
          filtered: false,
          installedPath: "/tmp/pi-tools",
        },
        {
          source: "npm:pi-theme",
          scope: "user",
          filtered: false,
          installedPath: "/tmp/pi-theme",
        },
      ],
      resolve: async (onMissing) => {
        missingSourceAction = await onMissing?.("npm:missing");
        return resolvedPaths([
          {
            path: "/tmp/pi-tools/extensions/index.ts",
            enabled: true,
            metadata: {
              source: "npm:pi-tools",
              scope: "user",
              origin: "package",
            },
          },
        ]);
      },
      installAndPersist: async () => {},
      update: async () => {},
      removeAndPersist: async () => true,
    };

    const coordinator = new ExtensionPackagesCoordinator(manager);

    expect(await coordinator.list()).toEqual({
      packages: [{
        source: "npm:pi-tools",
        scope: "user",
        filtered: false,
        installedPath: "/tmp/pi-tools",
        enabled: true,
      }],
    });
    expect(missingSourceAction).toBe("skip");
  });

  test("updates and removes the selected package through Pi's package manager", async () => {
    const calls: string[] = [];
    let configured = true;
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => configured
        ? [{
            source: "npm:pi-tools",
            scope: "user",
            filtered: true,
            installedPath: "/tmp/pi-tools",
          }]
        : [],
      resolve: async () => resolvedPaths(configured
        ? [{
            path: "/tmp/pi-tools/extensions/index.ts",
            enabled: false,
            metadata: {
              source: "npm:pi-tools",
              scope: "user",
              origin: "package",
            },
          }]
        : []),
      installAndPersist: async () => {},
      update: async (source) => { calls.push(`update:${source}`); },
      removeAndPersist: async (source, options) => {
        calls.push(`remove:${source}:${options?.local === true ? "project" : "user"}`);
        configured = false;
        return true;
      },
    };
    const coordinator = new ExtensionPackagesCoordinator(manager);

    expect(await coordinator.update("npm:pi-tools")).toMatchObject({
      packages: [{ source: "npm:pi-tools", enabled: false }],
    });
    expect(await coordinator.remove("npm:pi-tools", "user")).toEqual({ packages: [] });
    expect(calls).toEqual([
      "update:npm:pi-tools",
      "remove:npm:pi-tools:user",
    ]);
  });

  test("installs a user-scoped npm extension and persists it", async () => {
    const calls: string[] = [];
    let configured = false;
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => configured
        ? [{
            source: "npm:pi-tools",
            scope: "user",
            filtered: false,
            installedPath: "/tmp/pi-tools",
          }]
        : [],
      resolve: async () => resolvedPaths(configured
        ? [{
            path: "/tmp/pi-tools/extensions/index.ts",
            enabled: true,
            metadata: {
              source: "npm:pi-tools",
              scope: "user",
              origin: "package",
            },
          }]
        : []),
      installAndPersist: async (source, options) => {
        calls.push(`install:${source}:${options?.local === true ? "project" : "user"}`);
        configured = true;
      },
      update: async () => {},
      removeAndPersist: async () => true,
    };

    const coordinator = new ExtensionPackagesCoordinator(manager);

    expect(await coordinator.install("npm:pi-tools")).toMatchObject({
      packages: [{ source: "npm:pi-tools", enabled: true }],
    });
    expect(calls).toEqual(["install:npm:pi-tools:user"]);
  });

  test("flushes an installed extension before reloading the package list", async () => {
    const calls: string[] = [];
    const pendingSources: string[] = [];
    const configuredSources = new Set<string>();
    const settings = {
      getPackages: () => [],
      setPackages: () => {},
      flush: async () => {
        calls.push("flush");
        pendingSources.splice(0).forEach((source) => configuredSources.add(source));
      },
    };
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => Array.from(configuredSources).map((source) => ({
        source,
        scope: "user" as const,
        filtered: false,
        installedPath: `/tmp/${source.slice("npm:".length)}`,
      })),
      resolve: async () => resolvedPaths(Array.from(configuredSources).map((source) => ({
        path: `/tmp/${source.slice("npm:".length)}/index.ts`,
        enabled: true,
        metadata: { source, scope: "user", origin: "package" },
      }))),
      installAndPersist: async (source) => {
        calls.push(`install:${source}`);
        pendingSources.push(source);
      },
      update: async () => {},
      removeAndPersist: async () => true,
    };
    const coordinator = new ExtensionPackagesCoordinator(manager, settings);

    expect(await coordinator.install("npm:pi-tools")).toMatchObject({
      packages: [{ source: "npm:pi-tools", enabled: true }],
    });
    expect(calls.slice(0, 2)).toEqual(["install:npm:pi-tools", "flush"]);
  });

  test("disables and enables an installed package without uninstalling it", async () => {
    let packages: Array<string | {
      source: string;
      extensions?: string[];
      skills?: string[];
      prompts?: string[];
      themes?: string[];
    }> = ["npm:pi-tools"];
    const settings = {
      getPackages: (_scope: "user" | "project") => packages,
      setPackages: (
        _scope: "user" | "project",
        next: typeof packages,
      ) => { packages = next; },
      flush: async () => {},
    };
    const manager: ExtensionPackageManager = {
      listConfiguredPackages: () => [{
        source: "npm:pi-tools",
        scope: "user",
        filtered: typeof packages[0] === "object",
        installedPath: "/tmp/pi-tools",
      }],
      resolve: async () => resolvedPaths([{
        path: "/tmp/pi-tools/extensions/index.ts",
        enabled: typeof packages[0] === "string",
        metadata: {
          source: "npm:pi-tools",
          scope: "user",
          origin: "package",
        },
      }]),
      installAndPersist: async () => {},
      update: async () => {},
      removeAndPersist: async () => true,
    };
    const coordinator = new ExtensionPackagesCoordinator(manager, settings);

    expect(await coordinator.setEnabled("npm:pi-tools", "user", false)).toMatchObject({
      packages: [{ source: "npm:pi-tools", enabled: false }],
    });
    expect(packages).toEqual([{
      source: "npm:pi-tools",
      extensions: [],
      skills: [],
      prompts: [],
      themes: [],
    }]);

    expect(await coordinator.setEnabled("npm:pi-tools", "user", true)).toMatchObject({
      packages: [{ source: "npm:pi-tools", enabled: true }],
    });
    expect(packages).toEqual(["npm:pi-tools"]);
  });
});
