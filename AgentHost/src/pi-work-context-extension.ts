import {
  DefaultResourceLoader,
  getAgentDir,
  type InlineExtension,
  type ExtensionFactory,
  type SettingsManager,
} from "@earendil-works/pi-coding-agent";

export type PiWorkProfile = "chat" | "work";

type PiWorkContextOptions = {
  profile: PiWorkProfile;
  now?: () => Date;
  timeZone?: string;
  selectedGitBranch?: () => string | undefined;
};

function currentDate(date: Date, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const value = (type: Intl.DateTimeFormatPartTypes) => (
    parts.find((part) => part.type === type)?.value ?? ""
  );
  return `${value("year")}-${value("month")}-${value("day")}`;
}

function renderContext(options: PiWorkContextOptions): string {
  const timeZone = options.timeZone
    ?? Intl.DateTimeFormat().resolvedOptions().timeZone
    ?? "UTC";
  const purpose = options.profile === "chat"
    ? "General conversation and web research."
    : "Coding and project work.";
  return [
    "<pi_work_context>",
    `profile: ${options.profile}`,
    `current_date: ${currentDate(options.now?.() ?? new Date(), timeZone)}`,
    `timezone: ${timeZone}`,
    `purpose: ${purpose}`,
    "</pi_work_context>",
  ].join("\n");
}

export function piWorkContextExtension(options: PiWorkContextOptions): InlineExtension {
  return {
    name: "pi-work-context",
    hidden: true,
    factory: (pi) => {
      pi.on("before_agent_start", (event) => {
        const additions = [renderContext(options)];
        const branch = options.selectedGitBranch?.();
        if (branch) {
          additions.push(
            `The user selected ${JSON.stringify(branch)} as this session's target Git branch in pi-work. You are responsible for checking and managing the Git working state.`,
          );
        }
        return {
          systemPrompt: `${event.systemPrompt}\n\n${additions.join("\n\n")}`,
        };
      });
    },
  };
}

export async function createPiWorkResourceLoader(options: PiWorkContextOptions & {
  cwd: string;
  agentDir?: string;
  settingsManager?: SettingsManager;
  extensions?: ExtensionFactory[];
}): Promise<DefaultResourceLoader> {
  const loader = new DefaultResourceLoader({
    cwd: options.cwd,
    agentDir: options.agentDir ?? getAgentDir(),
    settingsManager: options.settingsManager,
    extensionFactories: [piWorkContextExtension(options), ...(options.extensions ?? [])],
    // This package is a managed desktop capability. A second user-installed
    // copy must not register unwrapped tools or eagerly prompt on macOS 13.
    extensionsOverride: (base) => ({ ...base, extensions: base.extensions.filter((extension) =>
      !extension.sourceInfo.source.startsWith("npm:@injaneity/pi-computer-use")
      && !extension.resolvedPath.includes("/@injaneity/pi-computer-use/")) }),
  });
  await loader.reload();
  return loader;
}
