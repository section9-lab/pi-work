import AppKit
import SwiftUI

/// Left sidebar: a segmented tab header, and — depending on which tab is
/// selected — either the "Chat" conversation-history list or the "Work"
/// folder workspace (nav placeholders + linked project folders), plus a
/// bottom-anchored account row. Layout mirrors the reference design.
///
/// The scrollable/selectable portion is a real system sidebar list
/// (`List(selection:)` + `.listStyle(.sidebar)`), not a hand-rolled
/// `ScrollView`/`VStack` — this gets keyboard navigation, hover states, and
/// accessibility for free from AppKit, while row content still renders our
/// own custom look via `.listRowBackground(Color.clear)` +
/// `.listRowInsets(EdgeInsets())`.

/// Which of the two sidebar surfaces is currently shown below the tab
/// header. `.chat` is project-free conversation; `.work` adds linked-folder
/// selection and project tools.
enum SidebarTab: Int, Hashable {
    case chat = 0
    case work = 1

    var showsProjectSelection: Bool { self == .work }
}

enum SidebarCustomDestination: Hashable {
    case schedule
    case skills
    case connectedApps

    var title: String {
        switch self {
        case .schedule: return L10n.string("sidebar.schedule")
        case .skills: return L10n.string("sidebar.skills")
        case .connectedApps: return L10n.string("sidebar.extensions")
        }
    }

    var icon: String {
        switch self {
        case .schedule: return "clock"
        case .skills: return "doc.text"
        case .connectedApps: return "puzzlepiece.extension"
        }
    }
}

struct SidebarView: View {
    @ObservedObject var projectStore: ProjectStore
    @Binding var selectedProject: PiProject?
    @Binding var selectedTab: SidebarTab
    var onAddFolder: () -> Void
    var onNewSession: () -> Void
    var onNewProjectSession: (PiProject) -> Void
    var chatSessions: [AgentHostSessionSummary] = []
    var selectedChatSessionId: String?
    var pendingChatSessionId: String?
    var onSelectChatSession: (AgentHostSessionSummary) -> Void = { _ in }
    var onDeleteChatSession: (AgentHostSessionSummary) -> Void = { _ in }
    var workSessionsByProjectPath: [String: [AgentHostSessionSummary]] = [:]
    var activeSessionIDs: Set<String> = []
    var selectedWorkSidebarItem: WorkSidebarItem? = nil
    var pendingWorkSidebarItem: WorkSidebarItem? = nil
    var onSelectWorkSession: (PiProject, AgentHostSessionSummary) -> Void = { _, _ in }
    var onExportWorkSession: (PiProject, AgentHostSessionSummary) -> Void = { _, _ in }
    var onDeleteWorkSession: (PiProject, AgentHostSessionSummary) -> Void = { _, _ in }
    var onDeleteWorkProject: (PiProject) -> Void = { _ in }
    var onSelectCustomDestination: (SidebarCustomDestination?) -> Void = { _ in }
    var updateController: AppUpdateController? = nil

    @State private var selectedCustomDestination: SidebarCustomDestination?
    @State private var projectDisclosureState = ProjectDisclosureState()
    @State private var changesProject: PiProject?

    var body: some View {
        VStack(spacing: 0) {
            SidebarTabHeader(selectedTab: $selectedTab)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .compositingGroup()

            switch selectedTab {
            case .chat:
                List(selection: $selectedProject) {
                    Section {
                        NavRow(
                            icon: "square.and.pencil",
                            title: L10n.string("sidebar.new"),
                            isSelected: false
                        ) {
                            selectedCustomDestination = nil
                            onSelectCustomDestination(nil)
                            onNewSession()
                        }
                    }

                    Section {
                        ForEach(chatSessions) { session in
                            ChatSessionRow(
                                session: session,
                                showsOpening: pendingChatSessionId == session.id,
                                isSelected: (pendingChatSessionId ?? selectedChatSessionId) == session.id,
                                action: {
                                    selectedProject = nil
                                    selectedCustomDestination = nil
                                    onSelectCustomDestination(nil)
                                    onSelectChatSession(session)
                                },
                                onDelete: { onDeleteChatSession(session) }
                            )
                        }
                    } header: {
                        SectionLabel(L10n.string("sidebar.history"))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

            case .work:
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        navigationRow(.schedule)
                        navigationRow(.skills)
                        navigationRow(.connectedApps)
                    }
                    .padding(.top, 8)

                    LinkedFoldersHeader(onAddFolder: onAddFolder)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 2)

                    List {
                        Section {
                            ForEach(projectStore.projects) { project in
                                let sessions = workSessionsByProjectPath[project.path] ?? []
                                let isExpanded = projectDisclosureState.isExpanded(project.id)
                                FolderRow(
                                    project: project,
                                    isSelected: displayedWorkSidebarItem == .project(project.id),
                                    isExpanded: isExpanded,
                                    onToggle: { toggleProject(project.id) },
                                    onNewSession: {
                                        expandProject(project.id)
                                        onNewProjectSession(project)
                                    },
                                    onDelete: { onDeleteWorkProject(project) }
                                )

                                if isExpanded {
                                    Button {
                                        changesProject = project
                                    } label: {
                                        Text(L10n.string("changes.title"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 24)
                                            .padding(.vertical, 6)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(L10n.string("changes.baseline"))
                                    if sessions.isEmpty {
                                        WorkSessionEmptyState()
                                    } else {
                                        ForEach(sessions) { session in
                                            WorkSessionRow(
                                                session: session,
                                                showsActivity: activeSessionIDs.contains(session.id),
                                                showsOpening: pendingWorkSidebarItem == .session(
                                                    projectID: project.id,
                                                    sessionID: session.id
                                                ),
                                                isSelected: displayedWorkSidebarItem == .session(
                                                        projectID: project.id,
                                                        sessionID: session.id
                                                    ),
                                                action: {
                                                    selectedCustomDestination = nil
                                                    onSelectCustomDestination(nil)
                                                    onSelectWorkSession(project, session)
                                                },
                                                onExport: { onExportWorkSession(project, session) },
                                                onDelete: { onDeleteWorkSession(project, session) }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }

            UserFooterView(updateController: updateController)
                .padding(.horizontal, 15)
                .padding(.top, 8)
                .padding(.bottom, 18)
                .compositingGroup()
                .frame(maxWidth: .infinity)
        }
        .background {
            if #available(macOS 26.0, *), NativeSidebarBackdropStabilizer.isRequired {
                NativeSidebarBackdropStabilizer()
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $changesProject) { project in
            ProjectChangesView(project: project)
        }
        .onChange(of: selectedProject?.id) { projectID in
            if projectID != nil { selectedCustomDestination = nil }
        }
    }

    private var displayedWorkSidebarItem: WorkSidebarItem? {
        pendingWorkSidebarItem ?? selectedWorkSidebarItem
    }

    private func navigationRow(_ destination: SidebarCustomDestination) -> some View {
        NavRow(
            icon: destination.icon,
            title: destination.title,
            isSelected: selectedCustomDestination == destination
        ) {
            selectedProject = nil
            selectedCustomDestination = destination
            onSelectCustomDestination(destination)
        }
    }

    private func toggleProject(_ projectID: UUID) {
        withAnimation(.easeOut(duration: 0.16)) {
            projectDisclosureState.toggle(projectID)
        }
    }

    private func expandProject(_ projectID: UUID) {
        guard !projectDisclosureState.isExpanded(projectID) else { return }
        toggleProject(projectID)
    }
}

@available(macOS 26.0, *)
private struct NativeSidebarBackdropStabilizer: NSViewRepresentable {
    static var isRequired: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
    }

    func makeNSView(context: Context) -> NativeSidebarBackdropAnchor {
        NativeSidebarBackdropAnchor()
    }

    func updateNSView(_ nsView: NativeSidebarBackdropAnchor, context: Context) {
        nsView.stabilizeBackdrop()
    }
}

@available(macOS 26.0, *)
final class NativeSidebarBackdropAnchor: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        stabilizeBackdrop()
        DispatchQueue.main.async { [weak self] in
            self?.stabilizeBackdrop()
        }
    }

    func stabilizeBackdrop() {
        guard let glass = firstGlassAncestor(),
              let container = glass.superview,
              let glassIndex = container.subviews.firstIndex(where: { $0 === glass }),
              glass.frame.minX > container.bounds.minX else {
            return
        }

        let outerBackdrop = container.subviews[..<glassIndex].last { sibling in
            sibling.frame.isApproximatelyEqual(to: container.bounds)
        }
        outerBackdrop?.isHidden = true
    }

    private func firstGlassAncestor() -> NSGlassEffectView? {
        var ancestor = superview
        while let current = ancestor {
            if let glass = current as? NSGlassEffectView {
                return glass
            }
            ancestor = current.superview
        }
        return nil
    }
}

private extension NSRect {
    func isApproximatelyEqual(to other: NSRect) -> Bool {
        abs(minX - other.minX) < 0.5
            && abs(minY - other.minY) < 0.5
            && abs(width - other.width) < 0.5
            && abs(height - other.height) < 0.5
    }
}

// MARK: - Pieces

/// Full-width segmented control at the top of the sidebar. Switches
/// `selectedTab` between conversation history ("Chat") and the folder
/// workspace ("Work"), which drives what the `List` below shows.
private struct SidebarTabHeader: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding var selectedTab: SidebarTab

    var body: some View {
        HStack(spacing: 0) {
            tab(title: L10n.string("sidebar.chat"), tab: .chat)
            tab(title: L10n.string("sidebar.work"), tab: .work)
        }
        .padding(3)
        .background {
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(AppPalette.segmentedTrack)

                GeometryReader { geometry in
                    let indicatorWidth = (geometry.size.width - 6) / 2

                    Capsule()
                        .fill(AppPalette.raisedSurface)
                        .shadow(color: AppPalette.subtleShadow, radius: 2, y: 1)
                        .frame(width: indicatorWidth, height: geometry.size.height - 6)
                        .offset(
                            x: 3 + CGFloat(selectedTab.rawValue) * indicatorWidth,
                            y: 3
                        )
                        .animation(
                            accessibilityReduceMotion ? nil : .easeOut(duration: 0.2),
                            value: selectedTab
                        )
                }
            }
        }
        .clipShape(Capsule())
    }

    private func tab(title: String, tab: SidebarTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.primary.opacity(isSelected ? 0.9 : 0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct NavRow: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary.opacity(0.78))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
        }
        .buttonStyle(
            RoundedInteractionButtonStyle(
                cornerRadius: 10,
                isSelected: isSelected,
                tracksHover: false
            )
        )
        .padding(.horizontal, 4)
        .compositingGroup()
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.primary.opacity(0.42))
            .compositingGroup()
    }
}

private struct ChatSessionRow: View {
    let session: AgentHostSessionSummary
    let showsOpening: Bool
    let isSelected: Bool
    let action: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(session.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsOpening {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text(L10n.string("chat.session_loading")))
                }
            }
            .foregroundStyle(Color.primary.opacity(0.78))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
        }
        .buttonStyle(
            RoundedInteractionButtonStyle(
                cornerRadius: 10,
                isSelected: isSelected,
                tracksHover: false
            )
        )
        .padding(.horizontal, 4)
        .compositingGroup()
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("chat-session-\(session.id)")
        .sessionContextMenu(sessionID: session.id, onDelete: onDelete)
    }
}

private struct FolderRow: View {
    let project: PiProject
    let isSelected: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        // NOTE: the padding that makes up the row's visible "pill" highlight
        // must live *inside* each button's own label, before `.buttonStyle`
        // is applied, with `.contentShape(Rectangle())` also inside the label
        // (right after the frame). Appending padding/contentShape *after*
        // `.buttonStyle` only grows the button's layout box — on macOS this
        // does not reliably grow the actual click/hit-test region, so the
        // toggle button would visually occupy the full pill but only its
        // rendered content (icon/text) would respond to clicks. Keeping
        // padding+contentShape together, inside the label, guarantees the
        // whole padded rectangle is genuinely clickable, matching the pill
        // that `.background` paints around it.
        HStack(spacing: 4) {
            Button {
                onToggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 14))
                        .frame(width: 18)
                    Text(project.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded
                ? L10n.format("sidebar.collapse_project", project.name)
                : L10n.format("sidebar.expand_project", project.name))
            .accessibilityLabel(isExpanded
                ? L10n.format("sidebar.collapse_project", project.name)
                : L10n.format("sidebar.expand_project", project.name))
            .accessibilityIdentifier("project-disclosure-\(project.id.uuidString)")

            Button(action: onNewSession) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .frame(width: 22, height: 22)
                    .padding(.vertical, 7)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 7))
            .opacity(showsHoverAction ? 1 : 0)
            .allowsHitTesting(showsHoverAction)
            .help(L10n.format("sidebar.new_project_session", project.name))
            .accessibilityLabel(L10n.format("sidebar.new_project_session", project.name))
            .accessibilityIdentifier("new-session-\(project.id.uuidString)")
            .accessibilityHidden(!showsHoverAction)
            .animation(.easeOut(duration: 0.12), value: showsHoverAction)
        }
        .foregroundStyle(Color.primary.opacity(0.78))
        .background(
            adaptiveRoundedShape(cornerRadius: 10)
                .fill(isSelected ? AppPalette.selectedRowFill : (isHovering ? AppPalette.hoverRowFill : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label(L10n.string("sidebar.remove_project"), systemImage: "trash")
            }
        }
        .confirmationDialog(
            L10n.format("sidebar.remove_project_title", project.name),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("sidebar.remove_project_action"), role: .destructive) {
                onDelete()
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("sidebar.remove_project_message"))
        }
        .padding(.leading, 0)
        .padding(.trailing, 4)
        .compositingGroup()
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var showsHoverAction: Bool {
        SidebarHoverActionVisibility(isHovering: isHovering).showsAction
    }
}

private struct WorkSessionRow: View {
    let session: AgentHostSessionSummary
    let showsActivity: Bool
    let showsOpening: Bool
    let isSelected: Bool
    let action: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(session.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsActivity || showsOpening {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.primary.opacity(0.55))
                        .accessibilityLabel(Text(L10n.string(
                            showsOpening ? "chat.session_loading" : "chat.tool.running"
                        )))
                }
            }
            .foregroundStyle(Color.primary.opacity(0.72))
            .padding(.leading, 20)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(
            RoundedInteractionButtonStyle(
                cornerRadius: 9,
                isSelected: isSelected,
                tracksHover: false
            )
        )
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .compositingGroup()
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("work-session-\(session.id)")
        .sessionContextMenu(
            sessionID: session.id,
            onExport: onExport,
            canExport: !showsActivity && !showsOpening,
            onDelete: onDelete
        )
    }
}

private extension View {
    func sessionContextMenu(
        sessionID: String,
        onExport: (() -> Void)? = nil,
        canExport: Bool = true,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(SessionContextMenuModifier(
            sessionID: sessionID,
            onExport: onExport,
            canExport: canExport,
            onDelete: onDelete
        ))
    }
}

private struct SessionContextMenuModifier: ViewModifier {
    let sessionID: String
    let onExport: (() -> Void)?
    let canExport: Bool
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(action: copySessionID) {
                    Label {
                        Text(L10n.string("sidebar.copy_session_id"))
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }

                if let onExport {
                    Button(action: onExport) {
                        Label {
                            Text(L10n.string("sidebar.export_html_report"))
                        } icon: {
                            Image(systemName: "doc.richtext")
                        }
                    }
                    .disabled(!canExport)
                }

                Divider()

                Button(role: .destructive, action: onDelete) {
                    Label {
                        Text(L10n.string("sidebar.delete_session"))
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
            .modifier(SessionContextMenuFocusModifier())
    }

    private func copySessionID() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sessionID, forType: .string)
    }
}

private struct SessionContextMenuFocusModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content.focusable(false)
        }
    }
}

private struct WorkSessionEmptyState: View {
    var body: some View {
        HStack(spacing: 0) {
            Text(L10n.string("sidebar.no_session"))
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.34))
            Spacer(minLength: 0)
        }
        .padding(.leading, 32)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .compositingGroup()
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("work-session-empty")
    }
}

private struct LinkedFoldersHeader: View {
    let onAddFolder: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.string("sidebar.project_folders"))
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.42))

            Spacer(minLength: 0)

            Button(action: onAddFolder) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 7))
            .opacity(showsHoverAction ? 1 : 0)
            .allowsHitTesting(showsHoverAction)
            .help(L10n.string("sidebar.add_mac_folder"))
            .accessibilityLabel(L10n.string("sidebar.add_mac_folder"))
            .accessibilityIdentifier("add-linked-folder")
            .accessibilityHidden(!showsHoverAction)
            .animation(.easeOut(duration: 0.12), value: showsHoverAction)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .compositingGroup()
    }

    private var showsHoverAction: Bool {
        SidebarHoverActionVisibility(isHovering: isHovering).showsAction
    }
}

/// Bottom-of-sidebar account row. Shows the signed-in user and opens the
/// account popover (settings / help / sign out).
private struct UserFooterView: View {
    @ObservedObject private var authSession = AuthSession.shared
    @State private var isPopoverPresented = false
    var updateController: AppUpdateController?

    private var displayName: String {
        authSession.user?.displayName ?? "pi-work"
    }

    private var initial: String {
        authSession.user?.avatarInitial ?? "p"
    }

    var body: some View {
        AppUpdateAccountRow(controller: updateController) { accountButton }
    }

    private var accountButton: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                AccountAvatarImage(
                    url: authSession.user?.avatarURL,
                    fallbackInitial: initial,
                    fallbackFontSize: 15
                )
                .frame(width: 30, height: 30)
                Text(displayName)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 10))
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            UserAccountPopover(
                isPresented: $isPopoverPresented,
                accountName: displayName,
                accountSubtitle: authSession.provider.accountSubtitle,
                accountInitial: initial,
                accountAvatarURL: authSession.user?.avatarURL,
                onSettings: {
                    openLegacySettings()
                },
                onHelp: { isPopoverPresented = false },
                onLogout: {
                    isPopoverPresented = false
                    authSession.signOut()
                }
            )
        }
    }

    private func openLegacySettings() {
        let opened = NSApp.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        )
        if !opened {
            NSApp.sendAction(
                Selector(("showPreferencesWindow:")),
                to: nil,
                from: nil
            )
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
