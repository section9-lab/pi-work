import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject private var sessionStore: SessionStore
    @ObservedObject private var installedExtensionsStore: InstalledExtensionsStore
    @ObservedObject private var scheduleStore: ScheduleStore
    private let scheduleRunner: ScheduleRunner
    @StateObject private var projectStore = ProjectStore()
    @State private var workSession = WorkSessionSelection()
    @State private var selectedTab: SidebarTab = .work
    @State private var selectedCustomDestination: SidebarCustomDestination?
    @StateObject private var skillsCatalogStore = SkillsCatalogStore()
    @StateObject private var extensionsCatalogStore = ExtensionsCatalogStore()
    @State private var didBootstrapChat = false
    @State private var bootstrappedWorkProjectPaths: Set<String> = []
    @State private var sessionOpeningState = SessionOpeningState()
    @State private var sessionOpenTask: Task<Void, Never>?
    @State private var agentError: String?
    @State private var exportingSessionIDs: Set<String> = []

    init(
        sessionStore: SessionStore,
        installedExtensionsStore: InstalledExtensionsStore,
        scheduleStore: ScheduleStore,
        scheduleRunner: ScheduleRunner
    ) {
        _sessionStore = ObservedObject(wrappedValue: sessionStore)
        _installedExtensionsStore = ObservedObject(wrappedValue: installedExtensionsStore)
        _scheduleStore = ObservedObject(wrappedValue: scheduleStore)
        self.scheduleRunner = scheduleRunner
    }

    var body: some View {
        splitView
            .frame(minWidth: 900, minHeight: 600)
            .task {
                await bootstrapChatIfNeeded()
                await bootstrapWorkProjects()
            }
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView(
                projectStore: projectStore,
                selectedProject: $workSession.selectedProject,
                selectedTab: selectedTabBinding,
                onAddFolder: pickFolder,
                onNewSession: startNewSession,
                onNewProjectSession: startNewSession(for:),
                chatSessions: sessionStore.chatSessions,
                selectedChatSessionId: sessionStore.selectedChatSessionId,
                pendingChatSessionId: sessionOpeningState.pendingChatSessionID,
                onSelectChatSession: openChatSession,
                onDeleteChatSession: deleteChatSession,
                workSessionsByProjectPath: sessionStore.workSessionsByProjectPath,
                activeSessionIDs: activeSessionIDs.union(exportingSessionIDs),
                selectedWorkSidebarItem: workSession.sidebarItem,
                pendingWorkSidebarItem: sessionOpeningState.pendingWorkSidebarItem,
                onSelectWorkSession: openWorkSession,
                onExportWorkSession: exportWorkSession,
                onDeleteWorkSession: deleteWorkSession,
                onDeleteWorkProject: deleteWorkProject,
                onSelectCustomDestination: {
                    if $0 != nil { cancelSessionOpening() }
                    selectedCustomDestination = $0
                }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
        } detail: {
            Group {
                if selectedTab == .work, selectedCustomDestination == .schedule {
                    ScheduleView(
                        store: scheduleStore,
                        runner: scheduleRunner,
                        projects: projectStore.projects
                    )
                } else if selectedTab == .work, selectedCustomDestination == .skills {
                    SkillsCatalogView(store: skillsCatalogStore)
                } else if selectedTab == .work,
                          selectedCustomDestination == .connectedApps {
                    ExtensionsCatalogView(
                        store: extensionsCatalogStore,
                        installedStore: installedExtensionsStore
                    )
                } else {
                    ChatView(
                        mode: selectedTab,
                        projects: projectStore.projects,
                        selectedProject: $workSession.selectedProject,
                        sessionStore: sessionStore,
                        hostError: agentError,
                        isLoadingSession: isOpeningSelectedSession,
                        onSelectProject: startNewSession(for:),
                        onAddFolder: pickFolder
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                AppBackgroundGradient()
            }
        }
    }

    private var activeSessionIDs: Set<String> {
        Set(
            sessionStore.records.values.compactMap { record in
                record.runState.showsSidebarActivity ? record.id : nil
            }
        )
    }

    private var selectedTabBinding: Binding<SidebarTab> {
        Binding(
            get: { selectedTab },
            set: { tab in
                guard tab != selectedTab else { return }
                cancelSessionOpening()
                selectedTab = tab
            }
        )
    }

    private func startNewSession() {
        cancelSessionOpening()
        selectedCustomDestination = nil
        switch selectedTab {
        case .chat:
            Task { await createChatSession() }
        case .work:
            workSession.startNewSession()
        }
    }

    private func startNewSession(for project: PiProject) {
        cancelSessionOpening()
        selectedTab = .work
        selectedCustomDestination = nil
        workSession.startNewSession(for: project)
        Task { await createWorkSession(for: project) }
    }

    private var isOpeningSelectedSession: Bool {
        guard let target = sessionOpeningState.target else { return false }
        switch (selectedTab, target.profile) {
        case (.chat, .chat):
            return true
        case (.work, .work):
            return true
        default:
            return false
        }
    }

    private func openChatSession(_ session: AgentHostSessionSummary) {
        selectedCustomDestination = nil
        guard !selectCachedSessionIfAvailable(session, profile: .chat) else { return }
        beginOpeningSession(session, profile: .chat)
    }

    private func bootstrapChatIfNeeded() async {
        guard !didBootstrapChat else { return }
        didBootstrapChat = true
        do {
            let directory = try prepareChatWorkingDirectory()
            try await sessionStore.bootstrap(
                cwd: directory.path,
                sessionDirectory: nil,
                profile: .chat
            )
            if sessionStore.selectedChatSessionId == nil {
                if let session = sessionStore.chatSessions.first {
                    try await sessionStore.openSession(
                        session,
                        profile: .chat,
                        sessionDirectory: nil
                    )
                } else {
                    _ = try await sessionStore.createDraft(
                        cwd: directory.path,
                        sessionDirectory: nil,
                        profile: .chat
                    )
                }
            }
            agentError = nil
        } catch {
            agentError = String(describing: error)
        }
    }

    private func createChatSession() async {
        do {
            let directory = try prepareChatWorkingDirectory()
            _ = try await sessionStore.createDraft(
                cwd: directory.path,
                sessionDirectory: nil,
                profile: .chat
            )
            agentError = nil
        } catch {
            agentError = String(describing: error)
        }
    }

    private func bootstrapWorkProjects() async {
        for project in projectStore.projects {
            await bootstrapWorkProjectIfNeeded(project)
        }
    }

    private func bootstrapWorkProjectIfNeeded(_ project: PiProject) async {
        guard !bootstrappedWorkProjectPaths.contains(project.path) else { return }
        bootstrappedWorkProjectPaths.insert(project.path)
        do {
            try await sessionStore.bootstrap(
                cwd: project.path,
                sessionDirectory: nil,
                profile: .work
            )
            agentError = nil
        } catch {
            bootstrappedWorkProjectPaths.remove(project.path)
            agentError = String(describing: error)
        }
    }

    private func createWorkSession(for project: PiProject) async {
        await bootstrapWorkProjectIfNeeded(project)
        do {
            _ = try await sessionStore.createDraft(
                cwd: project.path,
                sessionDirectory: nil,
                profile: .work
            )
            agentError = nil
        } catch {
            agentError = String(describing: error)
        }
    }

    private func openWorkSession(
        _ project: PiProject,
        _ session: AgentHostSessionSummary
    ) {
        selectedTab = .work
        selectedCustomDestination = nil
        guard !selectCachedSessionIfAvailable(
            session,
            profile: .work,
            project: project
        ) else { return }
        beginOpeningSession(session, profile: .work, project: project)
    }

    private func selectCachedSessionIfAvailable(
        _ session: AgentHostSessionSummary,
        profile: AgentHostSessionProfile,
        project: PiProject? = nil
    ) -> Bool {
        guard sessionStore.records[session.id] != nil else { return false }
        cancelSessionOpening()
        let performanceTraceID = sessionStore.beginSessionOpenPerformanceTrace(
            sessionID: session.id,
            profile: profile
        )
        do {
            try sessionStore.selectOpenSession(
                sessionId: session.id,
                profile: profile,
                cwd: session.cwd
            )
            if let project {
                workSession.selectSession(session.id, in: project)
            }
            sessionStore.markSessionOpenPerformanceTrace(
                performanceTraceID,
                stage: .cacheHit
            )
            sessionStore.markSessionOpenPerformanceTrace(
                performanceTraceID,
                stage: .selectionCommitted
            )
            agentError = nil
        } catch {
            sessionStore.failSessionOpenPerformanceTrace(performanceTraceID)
            agentError = String(describing: error)
        }
        return true
    }

    private func beginOpeningSession(
        _ session: AgentHostSessionSummary,
        profile: AgentHostSessionProfile,
        project: PiProject? = nil
    ) {
        sessionOpenTask?.cancel()
        let performanceTraceID = sessionStore.beginSessionOpenPerformanceTrace(
            sessionID: session.id,
            profile: profile
        )
        let request = sessionOpeningState.begin(
            SessionOpeningTarget(
                sessionID: session.id,
                profile: profile,
                cwd: session.cwd,
                projectID: project?.id
            )
        )
        sessionOpenTask = Task { @MainActor in
            await Task.yield()
            do {
                try await sessionStore.openSession(
                    session,
                    profile: profile,
                    sessionDirectory: nil,
                    selectSession: false,
                    performanceTraceID: performanceTraceID
                )
                try Task.checkCancellation()
                guard sessionOpeningState.isCurrent(request) else {
                    sessionStore.cancelSessionOpenPerformanceTrace(performanceTraceID)
                    return
                }
                try commitSessionSelection(for: request.target)
                sessionStore.markSessionOpenPerformanceTrace(
                    performanceTraceID,
                    stage: .selectionCommitted
                )
                sessionOpeningState.complete(request)
                agentError = nil
            } catch is CancellationError {
                sessionStore.cancelSessionOpenPerformanceTrace(performanceTraceID)
                return
            } catch {
                sessionStore.failSessionOpenPerformanceTrace(performanceTraceID)
                guard sessionOpeningState.complete(request) else { return }
                agentError = String(describing: error)
            }
        }
    }

    private func commitSessionSelection(for target: SessionOpeningTarget) throws {
        let project = target.projectID.flatMap { projectID in
            projectStore.projects.first { $0.id == projectID && $0.path == target.cwd }
        }
        if target.profile == .work, project == nil {
            throw SessionStoreError.sessionNotOpen(target.sessionID)
        }
        try sessionStore.selectOpenSession(
            sessionId: target.sessionID,
            profile: target.profile,
            cwd: target.cwd
        )
        if let project {
            workSession.selectSession(target.sessionID, in: project)
        }
    }

    private func cancelSessionOpening() {
        sessionOpenTask?.cancel()
        sessionOpenTask = nil
        sessionOpeningState.cancel()
    }

    private func deleteChatSession(_ session: AgentHostSessionSummary) {
        Task {
            do {
                try await sessionStore.deleteSession(
                    session,
                    profile: .chat,
                    sessionDirectory: nil
                )
                agentError = nil
            } catch {
                agentError = String(describing: error)
            }
        }
    }

    private func deleteWorkSession(
        _ project: PiProject,
        _ session: AgentHostSessionSummary
    ) {
        guard project.path == session.cwd else { return }
        Task {
            do {
                try await sessionStore.deleteSession(
                    session,
                    profile: .work,
                    sessionDirectory: nil
                )
                agentError = nil
            } catch {
                agentError = String(describing: error)
            }
        }
    }

    private func exportWorkSession(
        _ project: PiProject,
        _ session: AgentHostSessionSummary
    ) {
        guard project.path == session.cwd,
              !activeSessionIDs.contains(session.id),
              !exportingSessionIDs.contains(session.id) else { return }
        exportingSessionIDs.insert(session.id)
        Task {
            defer { exportingSessionIDs.remove(session.id) }
            do {
                let reportURL = try await sessionStore.exportHTMLReport(
                    session,
                    profile: .work,
                    sessionDirectory: nil
                )
                guard NSWorkspace.shared.open(reportURL) else {
                    throw SessionStoreError.cannotOpenExportedReport(reportURL.path)
                }
                agentError = nil
            } catch {
                agentError = String(describing: error)
            }
        }
    }

    private func deleteWorkProject(_ project: PiProject) {
        Task {
            do {
                try await sessionStore.deleteWorkSessions(
                    cwd: project.path,
                    sessionDirectory: nil
                )
                if workSession.selectedProject?.id == project.id {
                    workSession.startNewSession()
                }
                bootstrappedWorkProjectPaths.remove(project.path)
                projectStore.removeProject(project)
                agentError = nil
            } catch {
                agentError = String(describing: error)
            }
        }
    }

    private func prepareChatWorkingDirectory() throws -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pi-work/Chat", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("sidebar.add_mac_folder")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectStore.addProject(path: url.path)
        guard let project = projectStore.projects.first(where: { $0.path == url.path }) else { return }
        startNewSession(for: project)
    }
}

/// Single window-spanning gradient drawn once behind the sidebar + content
/// split, so the two panels share one continuous background instead of each
/// drawing its own — matching the reference design's unified backdrop.
/// See `AppPalette.windowGradient` for the light/dark stops.
struct AppBackgroundGradient: View {
    var body: some View {
        AppPalette.windowGradient
            .ignoresSafeArea()
    }
}

#Preview {
    let service = AgentHostService(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        requiredCapabilities: []
    )
    let sessionStore = SessionStore(service: service)
    let scheduleStore = ScheduleStore()
    ContentView(
        sessionStore: sessionStore,
        installedExtensionsStore: InstalledExtensionsStore(service: service),
        scheduleStore: scheduleStore,
        scheduleRunner: ScheduleRunner(
            store: scheduleStore,
            executor: ScheduleAgentExecutor(sessionClient: sessionStore)
        )
    )
}
