import {
  DefaultPackageManager,
  getAgentDir,
  type PackageManager,
} from "@earendil-works/pi-coding-agent";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import packageMetadata from "../package.json";

import {
  agentDirectory,
  createAgentSettingsManager,
} from "./agent-settings.ts";
import { PiWebAccessSettingsCoordinator } from "./pi-web-access-settings.ts";

export type ExtensionPackageScope = "user" | "project";
export const requiredPiWebAccessSource = "npm:pi-web-access";
export const requiredPiWebAccessRuntimeSource =
  `npm:@earendil-works/pi-coding-agent@${packageMetadata.dependencies["@earendil-works/pi-coding-agent"]}`;

export type InstalledExtensionPackage = {
  source: string;
  scope: ExtensionPackageScope;
  filtered: boolean;
  installedPath?: string;
  version?: string;
  enabled: boolean;
};

export type InstalledExtensionPackagesSnapshot = {
  packages: InstalledExtensionPackage[];
};

export type ExtensionPackageManager = Pick<
  PackageManager,
  | "listConfiguredPackages"
  | "resolve"
  | "installAndPersist"
  | "update"
  | "removeAndPersist"
>;

type ExtensionPackageSource = string | {
  source: string;
  extensions?: string[];
  skills?: string[];
  prompts?: string[];
  themes?: string[];
};

export type ExtensionPackageSettings = {
  getPackages(scope: ExtensionPackageScope): ExtensionPackageSource[];
  setPackages(scope: ExtensionPackageScope, packages: ExtensionPackageSource[]): void;
  flush(): Promise<void>;
};

export class ExtensionPackagesCoordinator {
  constructor(
    private readonly packageManager: ExtensionPackageManager,
    private readonly settings?: ExtensionPackageSettings,
    private readonly piWebAccessSettings?: PiWebAccessSettingsCoordinator,
  ) {}

  async list(): Promise<InstalledExtensionPackagesSnapshot> {
    await this.ensurePiWebAccess();
    const configured = this.packageManager.listConfiguredPackages();
    const resolved = await this.packageManager.resolve(async () => "skip");

    return {
      packages: (await Promise.all(configured.map(async (pkg) => {
        const resources = resolved.extensions.filter((resource) => (
          resource.metadata.origin === "package"
          && resource.metadata.source === pkg.source
          && resource.metadata.scope === pkg.scope
        ));
        if (resources.length === 0) return [];

        const version = await installedVersion(pkg.installedPath);
        return [{
          source: pkg.source,
          scope: pkg.scope,
          filtered: pkg.filtered,
          installedPath: pkg.installedPath,
          ...(version ? { version } : {}),
          enabled: resources.some((resource) => resource.enabled),
        }];
      }))).flat().sort((left, right) => left.source.localeCompare(right.source)),
    };
  }

  async install(source: string): Promise<InstalledExtensionPackagesSnapshot> {
    await this.packageManager.installAndPersist(source, { local: false });
    await this.settings?.flush();
    return this.list();
  }

  async setEnabled(
    source: string,
    scope: ExtensionPackageScope,
    enabled: boolean,
  ): Promise<InstalledExtensionPackagesSnapshot> {
    if (source === requiredPiWebAccessSource && !enabled) {
      throw new Error("pi-web-access is required and cannot be disabled");
    }
    if (!this.settings) throw new Error("Extension package settings are unavailable");
    const packages = this.settings.getPackages(scope);
    const index = packages.findIndex((pkg) => (
      (typeof pkg === "string" ? pkg : pkg.source) === source
    ));
    if (index < 0) throw new Error(`No matching extension package found: ${source}`);

    const next = [...packages];
    next[index] = enabled
      ? source
      : {
          source,
          extensions: [],
          skills: [],
          prompts: [],
          themes: [],
        };
    this.settings.setPackages(scope, next);
    await this.settings.flush();
    return this.list();
  }

  async update(source: string): Promise<InstalledExtensionPackagesSnapshot> {
    await this.packageManager.update(source);
    return this.list();
  }

  async remove(
    source: string,
    scope: ExtensionPackageScope,
  ): Promise<InstalledExtensionPackagesSnapshot> {
    if (source === requiredPiWebAccessSource) {
      throw new Error("pi-web-access is required and cannot be removed");
    }
    const removed = await this.packageManager.removeAndPersist(source, {
      local: scope === "project",
    });
    if (!removed) throw new Error(`No matching extension package found: ${source}`);
    return this.list();
  }

  private async ensurePiWebAccess(): Promise<void> {
    if (process.env.PI_WORK_SKIP_REQUIRED_EXTENSION_INSTALL === "1") return;
    await this.piWebAccessSettings?.get();
    const configuredPackages = this.packageManager.listConfiguredPackages();
    if (!configuredPackages.some((pkg) => (
      pkg.source === requiredPiWebAccessRuntimeSource && pkg.scope === "user"
    ))) {
      await this.packageManager.installAndPersist(
        requiredPiWebAccessRuntimeSource,
        { local: false },
      );
    }
    const requiredPackage = this.packageManager.listConfiguredPackages().find((pkg) => (
      pkg.source === requiredPiWebAccessSource && pkg.scope === "user"
    ));
    if (!requiredPackage) {
      await this.packageManager.installAndPersist(requiredPiWebAccessSource, { local: false });
    } else if (requiredPackage.filtered && this.settings) {
      const packages = this.settings.getPackages("user");
      const next = packages.map((pkg) => (
        (typeof pkg === "string" ? pkg : pkg.source) === requiredPiWebAccessSource
          ? requiredPiWebAccessSource
          : pkg
      ));
      this.settings.setPackages("user", next);
      await this.settings.flush();
    }
  }
}

async function installedVersion(installedPath: string | undefined): Promise<string | undefined> {
  if (!installedPath) return undefined;
  try {
    const manifest = JSON.parse(await readFile(join(installedPath, "package.json"), "utf8"));
    return typeof manifest?.version === "string" ? manifest.version.trim() || undefined : undefined;
  } catch {
    // Local extensions and older packages may not have a readable manifest.
    return undefined;
  }
}

export function createExtensionPackagesCoordinator(
  cwd: string,
  environment: Record<string, string | undefined>,
): ExtensionPackagesCoordinator {
  const resolvedAgentDirectory = agentDirectory(environment) ?? getAgentDir();
  const settingsManager = createAgentSettingsManager(cwd, environment);
  return new ExtensionPackagesCoordinator(
    new DefaultPackageManager({
      cwd,
      agentDir: resolvedAgentDirectory,
      settingsManager,
    }),
    {
      getPackages: (scope) => (
        scope === "user"
          ? settingsManager.getGlobalSettings().packages ?? []
          : settingsManager.getProjectSettings().packages ?? []
      ),
      setPackages: (scope, packages) => {
        if (scope === "user") settingsManager.setPackages(packages);
        else settingsManager.setProjectPackages(packages);
      },
      flush: () => settingsManager.flush(),
    },
    new PiWebAccessSettingsCoordinator(resolvedAgentDirectory),
  );
}
