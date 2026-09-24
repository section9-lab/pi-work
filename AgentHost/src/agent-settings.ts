import { SettingsManager } from "@earendil-works/pi-coding-agent";

export type AgentThinkingLevel =
  | "off"
  | "minimal"
  | "low"
  | "medium"
  | "high"
  | "xhigh"
  | "max";

export type AgentTransport = "auto" | "sse" | "websocket" | "websocket-cached";

export type AgentSettingsSnapshot = {
  defaultModel: { provider: string; modelId: string } | null;
  defaultThinkingLevel: AgentThinkingLevel;
  transport: AgentTransport;
  compactionEnabled: boolean;
  retryEnabled: boolean;
};

export type AgentSettingsPatch = Partial<AgentSettingsSnapshot>;

export class AgentSettingsCoordinator {
  constructor(private readonly settings: SettingsManager) {}

  snapshot(): AgentSettingsSnapshot {
    const provider = this.settings.getDefaultProvider();
    const modelId = this.settings.getDefaultModel();
    return {
      defaultModel: provider && modelId ? { provider, modelId } : null,
      defaultThinkingLevel: this.settings.getDefaultThinkingLevel() ?? "off",
      transport: this.settings.getTransport(),
      compactionEnabled: this.settings.getCompactionEnabled(),
      retryEnabled: this.settings.getRetryEnabled(),
    };
  }

  async update(patch: AgentSettingsPatch): Promise<AgentSettingsSnapshot> {
    if (patch.defaultModel) {
      this.settings.setDefaultModelAndProvider(
        patch.defaultModel.provider,
        patch.defaultModel.modelId,
      );
    }
    if (patch.defaultThinkingLevel !== undefined) {
      this.settings.setDefaultThinkingLevel(patch.defaultThinkingLevel);
    }
    if (patch.transport !== undefined) {
      this.settings.setTransport(patch.transport);
    }
    if (patch.compactionEnabled !== undefined) {
      this.settings.setCompactionEnabled(patch.compactionEnabled);
    }
    if (patch.retryEnabled !== undefined) {
      this.settings.setRetryEnabled(patch.retryEnabled);
    }
    await this.settings.flush();
    return this.snapshot();
  }
}

export function createAgentSettingsManager(
  cwd: string,
  environment: Record<string, string | undefined>,
): SettingsManager {
  const settings = SettingsManager.create(cwd, agentDirectory(environment), { projectTrusted: false });
  const bunPath = environment.PI_WORK_BUN_PATH?.trim();
  if (bunPath) {
    // Keep desktop packages independent of the terminal's registry and cached manifest URLs.
    const command = [bunPath, "--registry=https://registry.npmjs.org", "--no-cache"];
    if (JSON.stringify(settings.getNpmCommand()) !== JSON.stringify(command)) {
      settings.setNpmCommand(command);
    }
  }
  return settings;
}

export function createAgentSettingsCoordinator(
  cwd: string,
  environment: Record<string, string | undefined>,
): AgentSettingsCoordinator {
  return new AgentSettingsCoordinator(createAgentSettingsManager(cwd, environment));
}

export function agentDirectory(
  environment: Record<string, string | undefined>,
): string | undefined {
  return environment.PI_WORK_AGENT_DIR?.trim()
    || environment.PI_CODING_AGENT_DIR?.trim()
    || undefined;
}
