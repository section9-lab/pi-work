import AppKit
import Combine
import Foundation
import SwiftUI

@main
struct PiWorkApp: App {
    @StateObject private var authSession = AuthSession.shared
    @StateObject private var agentRuntime = AppAgentRuntime()
    @StateObject private var updateController = AppUpdateController()
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some Scene {
        WindowGroup {
            RootView(
                authSession: authSession,
                agentRuntime: agentRuntime,
                languageStore: languageStore,
                updateController: updateController
            )
                .onAppear { ForegroundUsageTracker.shared.start() }
                .task {
#if DEBUG
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
#endif
                    updateController.observeTaskActivity(agentRuntime.updateTaskActivity) {
                        agentRuntime.hasTasksPreventingAppUpdate
                    }
                    updateController.start()
                }
                .environment(\.locale, languageStore.language.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 900, height: 680)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button(L10n.format("about.menu", applicationName)) {
                    showAboutPanel()
                }
            }
            CommandGroup(after: .appInfo) {
                Button(L10n.string("update.check")) {
                    updateController.checkForUpdatesAndPresent()
                }
                .disabled(!updateController.canCheckForUpdates || updateController.isInstalling)
            }
        }

        Settings {
            if let agentSettingsStore = agentRuntime.agentSettingsStore,
               let providerAuthStore = agentRuntime.providerAuthStore,
               let installedExtensionsStore = agentRuntime.installedExtensionsStore,
               let mcpStore = agentRuntime.mcpStore,
               let computerUseStore = agentRuntime.computerUseStore,
               let rtkStore = agentRuntime.rtkStore,
               let runtimeUpdateController = agentRuntime.runtimeUpdateController {
                AppSettingsView(
                    agentSettingsStore: agentSettingsStore,
                    providerAuthStore: providerAuthStore,
                    installedExtensionsStore: installedExtensionsStore,
                    mcpStore: mcpStore,
                    computerUseStore: computerUseStore,
                    rtkStore: rtkStore,
                    languageStore: languageStore,
                    updateController: updateController,
                    runtimeUpdateController: runtimeUpdateController
                )
                    .preferredColorScheme(themeStore.theme.colorScheme)
                    .environment(\.locale, languageStore.language.locale)
            } else {
                AgentRuntimeUnavailableView(
                    message: agentRuntime.errorMessage ?? L10n.string("agent.host_unavailable")
                )
                .frame(width: 620, height: 440)
                .environment(\.locale, languageStore.language.locale)
            }
        }
        .defaultSize(width: 720, height: 620)
        .windowResizability(.contentMinSize)
    }

    private var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PiWork"
    }

    private func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let version = agentRuntime.runtimeUpdateController?.currentPiVersion,
           !version.isEmpty {
            options[.credits] = NSAttributedString(
                string: "pi-coding-agent \(version)"
            )
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// Gates the app on a valid session: onboarding until signed in, the project
/// shell afterwards. `restoreSessionOnLaunch` runs once on cold start and
/// silently refreshes an expired access token when it can.
private struct RootView: View {
    @ObservedObject var authSession: AuthSession
    @ObservedObject var agentRuntime: AppAgentRuntime
    @ObservedObject var languageStore: LanguageStore
    @ObservedObject var updateController: AppUpdateController
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var didRestore = false

    var body: some View {
        Group {
            if authSession.isSignedIn {
                if let sessionStore = agentRuntime.sessionStore,
                   let installedExtensionsStore = agentRuntime.installedExtensionsStore,
                   let scheduleRunner = agentRuntime.scheduleRunner {
                    ContentView(
                        sessionStore: sessionStore,
                        computerUseStore: agentRuntime.computerUseStore,
                        installedExtensionsStore: installedExtensionsStore,
                        scheduleStore: agentRuntime.scheduleStore,
                        scheduleRunner: scheduleRunner,
                        updateController: updateController
                    )
                } else {
                    AgentRuntimeUnavailableView(
                        message: agentRuntime.errorMessage ?? L10n.string("agent.host_unavailable")
                    )
                }
            } else {
                OnboardingLoginView(authSession: authSession)
            }
        }
        // Applied at the root so onboarding follows the choice too. `nil`
        // means "follow the system", which is the default.
        .preferredColorScheme(themeStore.theme.colorScheme)
        .overlay(alignment: .top) {
            // Hidden title bars lose native drag / double-click zoom. Restore
            // them on the empty top chrome for every root surface.
            WindowTitlebarDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .ignoresSafeArea(edges: .top)
        }
        .task {
#if DEBUG
            let environment = ProcessInfo.processInfo.environment
            guard environment["XCTestConfigurationFilePath"] == nil,
                  !CommandLine.arguments.contains("--pi-work-skip-auth-restore") else {
                return
            }
#endif
            guard !didRestore else { return }
            didRestore = true
            await authSession.restoreSessionOnLaunch()
        }
        .task(id: authSession.isSignedIn) {
            if authSession.isSignedIn {
                await agentRuntime.runtimeUpdateController?.start()
                await agentRuntime.computerUseStore?.load(check: true)
                agentRuntime.scheduleRunner?.start()
            } else {
                agentRuntime.scheduleRunner?.stop()
            }
        }
    }
}

@MainActor
final class AppAgentRuntime: ObservableObject {
    let service: AgentHostService?
    let sessionStore: SessionStore?
    let agentSettingsStore: AgentSettingsStore?
    let providerAuthStore: ProviderAuthStore?
    let installedExtensionsStore: InstalledExtensionsStore?
    let mcpStore: MCPStore?
    let computerUseStore: ComputerUseStore?
    let rtkStore: RTKStore?
    let runtimeUpdateController: AgentRuntimeUpdateController?
    let scheduleStore: ScheduleStore
    let scheduleRunner: ScheduleRunner?
    let errorMessage: String?

    var hasTasksPreventingAppUpdate: Bool {
        sessionStore?.records.values.contains { $0.runState.preventsAppUpdate } == true
            || scheduleRunner?.runningTaskIDs.isEmpty == false
    }

    var updateTaskActivity: AnyPublisher<Bool, Never> {
        let sessions = sessionStore?.recordsPublisher
            .map { $0.values.contains { $0.runState.preventsAppUpdate } }
            .removeDuplicates()
            .eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()
        let schedules = scheduleRunner?.$runningTaskIDs.map { !$0.isEmpty }
            .eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()
        return Publishers.CombineLatest(sessions, schedules)
        .map { $0 || $1 }
        .eraseToAnyPublisher()
    }

    init() {
        let scheduleStore = ScheduleStore()
        self.scheduleStore = scheduleStore
        do {
            // The agent is released with PiWork; never select a separately installed runtime.
            let service = try AgentHostService.bundled()
            runtimeUpdateController = AgentRuntimeUpdateController(service: service)
            let sessionStore = SessionStore(service: service)
            self.service = service
            self.sessionStore = sessionStore
            agentSettingsStore = AgentSettingsStore(service: service)
            providerAuthStore = ProviderAuthStore(service: service)
            installedExtensionsStore = InstalledExtensionsStore(service: service)
            mcpStore = MCPStore(service: service)
            computerUseStore = ComputerUseStore(service: service)
            rtkStore = RTKStore(service: service)
            scheduleRunner = ScheduleRunner(
                store: scheduleStore,
                executor: ScheduleAgentExecutor(sessionClient: sessionStore)
            )
            errorMessage = nil
        } catch {
            service = nil
            sessionStore = nil
            agentSettingsStore = nil
            providerAuthStore = nil
            installedExtensionsStore = nil
            mcpStore = nil
            computerUseStore = nil
            rtkStore = nil
            runtimeUpdateController = nil
            scheduleRunner = nil
            errorMessage = String(describing: error)
        }
    }
}

private struct AgentRuntimeUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
            Text(L10n.string("agent.unavailable"))
                .font(.headline)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
