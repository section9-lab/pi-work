import AppKit
import SwiftUI

/// Conversation/review layout only. Custom window-chrome controls are separate
/// overlays, so neither a title row nor a native toolbar changes navigation.
struct ProjectChangesWorkspace<Content: View>: View {
    let project: PiProject?
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content
    @State private var preferredReviewWidth: CGFloat = 420
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let layout = ProjectReviewLayout(
                availableWidth: geometry.size.width,
                preferredWidth: preferredReviewWidth,
                isPresented: isPresented && project != nil
            )
            ZStack(alignment: .trailing) {
                // Stable identity while opening menus/panes preserves the draft.
                content()
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                if isPresented, let project {
                    ProjectChangesView(project: project) { isPresented = false }
                        .id(project.path)
                        .frame(width: layout.reviewWidth)
                        .overlay(alignment: .leading) { resizeHandle(layout) }
                        .shadow(color: .black.opacity(layout.overlaysContent ? 0.12 : 0), radius: 12, x: -4)
                }
            }
            .clipped()
            .preference(key: ProjectReviewControlInsetKey.self,
                value: layout.overlaysContent || layout.reviewWidth == 0 ? 0 : layout.reviewWidth + 1)
        }
    }

    private func resizeHandle(_ layout: ProjectReviewLayout) -> some View {
        Rectangle().fill(Color.primary.opacity(0.12))
            .frame(width: 1)
            .overlay {
                Color.clear.frame(width: 10).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStartWidth ?? layout.reviewWidth
                            dragStartWidth = start
                            preferredReviewWidth = min(ProjectReviewLayout.maximumReviewWidth,
                                max(ProjectReviewLayout.minimumReviewWidth, start - value.translation.width))
                        }
                        .onEnded { _ in dragStartWidth = nil })
            }
            .accessibilityLabel(L10n.string("changes.resize"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    preferredReviewWidth = min(ProjectReviewLayout.maximumReviewWidth, preferredReviewWidth + 40)
                case .decrement:
                    preferredReviewWidth = max(ProjectReviewLayout.minimumReviewWidth, preferredReviewWidth - 40)
                @unknown default: break
                }
            }
    }
}

struct ProjectReviewControlInsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ProjectSessionMenuAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Custom window chrome: no native toolbar, title row, or NSPopover. The card
/// stays below the button and within this window, including on small displays.
struct ProjectSessionMenuOverlay: View {
    let project: PiProject
    var reviewTrailingInset: CGFloat = 0
    @Binding var isReviewPresented: Bool
    @State private var showsProjectMenu = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear.allowsHitTesting(false)
            Button { showsProjectMenu.toggle() } label: {
                ProjectSessionMenuIcon().frame(width: 36, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(showsProjectMenu || isReviewPresented ? 0.08 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsProjectMenu ? "" : L10n.string("changes.project_menu"))
            .accessibilityLabel(L10n.string("changes.project_menu"))
            .accessibilityIdentifier("project-session-menu-toggle")
            .background(WindowTitlebarControlRegion())
            .anchorPreference(key: ProjectSessionMenuAnchorKey.self, value: .bounds) { $0 }
            .padding(.top, 10)
            .padding(.trailing, 16 + reviewTrailingInset)
        }
        .overlayPreferenceValue(ProjectSessionMenuAnchorKey.self) { anchor in
            GeometryReader { geometry in
                InWindowFloatingPanel(
                    isPresented: $showsProjectMenu,
                    layout: BoundedFloatingPanelLayout(idealWidth: 320, idealMaximumHeight: 180,
                        inset: 12, anchorGap: 8, pointerTrailingInset: 16),
                    anchorFrame: anchor.map { geometry[$0] },
                    showsPointer: false,
                    fillsHeight: false
                ) {
                    ProjectSessionReviewMenu(project: project) { isReviewPresented = true }
                        .id(project.path)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .onChange(of: project.path) { _ in showsProjectMenu = false }
    }
}

private struct ProjectSessionMenuIcon: View {
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<2) { _ in
                HStack(spacing: 4) {
                    Circle().stroke(lineWidth: 1.2).frame(width: 4, height: 4)
                    Capsule().frame(width: 9, height: 1.2)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct ProjectSessionReviewMenu: View {
    let project: PiProject
    let onReview: () -> Void
    @State private var snapshot: ProjectChangesSnapshot?
    @State private var summary: ProjectChangesSummary?
    @State private var failed = false
    @State private var isHoveringReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(project.name).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    if let snapshot { Text(snapshot.branch) }
                    Button(L10n.string("changes.copy_path")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(project.path, forType: .string)
                    }
                    Button(L10n.string("changes.reveal_project")) {
                        NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L10n.string("changes.project_menu"))
            }
            .padding(.horizontal, 8)
            Button(action: onReview) {
                HStack(spacing: 12) {
                    Image(systemName: "plus.forwardslash.minus").frame(width: 18)
                    Text(L10n.string("changes.menu_changes")).fontWeight(.medium)
                    Spacer()
                    if let summary {
                        HStack(spacing: 5) {
                            Text("+\(summary.additions)").foregroundStyle(.green)
                            Text("−\(summary.deletions)").foregroundStyle(.red)
                        }.font(.system(size: 12, design: .monospaced))
                    } else if let snapshot {
                        Text(L10n.format("changes.file_count", snapshot.files.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 10).contentShape(Rectangle())
                .background(Color.primary.opacity(isHoveringReview ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringReview = $0 }
            .accessibilityIdentifier("project-changes-toggle")
            if failed {
                Text(L10n.string("changes.unavailable")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .accessibilityIdentifier("project-session-menu")
        .task(id: project.path) {
            do {
                let path = project.path
                let result = try await Task.detached(priority: .userInitiated) {
                    try ProjectChangesService.snapshot(at: path)
                }.value
                guard !Task.isCancelled else { return }
                snapshot = result
                let totals = await Task.detached(priority: .utility) {
                    ProjectChangesService.summary(in: result)
                }.value
                guard !Task.isCancelled else { return }
                summary = totals
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

/// A project-scoped, read-only review pane alongside the conversation.
/// Its presentation belongs to the workspace, never to an individual session.
struct ProjectChangesView: View {
    let project: PiProject
    let onClose: () -> Void
    @State private var snapshot: ProjectChangesSnapshot?
    @State private var selectedPath: String?
    @State private var diff: FileDiff?
    @State private var error: String?
    @State private var diffError: String?
    @State private var loading = true
    @State private var loadingDiff = false
    @State private var revision = UUID()
    @State private var refresh = UUID()
    @State private var query = ""

    private var selectedFile: ChangedFile? { snapshot?.files.first { $0.path == selectedPath } }
    private var visibleFiles: [ChangedFile] {
        (snapshot?.files ?? []).filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading && snapshot == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                placeholder(title: L10n.string("changes.unavailable"), detail: error)
            } else if let snapshot, snapshot.files.isEmpty {
                placeholder(title: L10n.string("changes.clean"), detail: L10n.string("changes.clean_detail"))
            } else {
                VSplitView {
                    fileList.frame(minHeight: 100, idealHeight: 180, maxHeight: 280)
                    diffPane.frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text(L10n.string("changes.baseline"))
                Spacer()
                if let snapshot { Text(L10n.format("changes.file_count", snapshot.files.count)) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.raisedSurface)
        .accessibilityIdentifier("project-changes-panel")
        .task(id: refresh) { await loadSnapshot() }
        .task(id: "\(revision)-\(selectedPath ?? "")") { await loadDiff() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("changes.title")).font(.headline)
                HStack(spacing: 8) {
                    Text(project.name)
                    if let snapshot { Text("·"); Text(snapshot.branch) }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { refresh = UUID() } label: {
                Image("LucideRefreshCw").renderingMode(.template).resizable().scaledToFit().frame(width: 14, height: 14)
            }
                .help(L10n.string("changes.refresh")).disabled(loading)
                .accessibilityLabel(L10n.string("changes.refresh"))
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
            }
            .help(L10n.string("changes.done"))
            .accessibilityLabel(L10n.string("changes.done"))
            .accessibilityIdentifier("project-changes-close")
        }.buttonStyle(.borderless).padding(14)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            TextField(L10n.string("changes.filter"), text: $query)
                .textFieldStyle(.roundedBorder).padding(12)
            if visibleFiles.isEmpty && !query.isEmpty {
                Text(L10n.string("changes.no_matches"))
                    .font(.callout).foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedPath) {
                    ForEach(visibleFiles) { file in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(fileURLWithPath: file.path).lastPathComponent).font(.system(size: 12, weight: .medium))
                                Text(file.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Text(file.badge).font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(file.badge == "D" ? Color.red : file.badge == "M" ? Color.orange : Color.green)
                        }
                        .padding(.vertical, 5).tag(file.path)
                        .help(file.status + "  " + file.path)
                    }
                }.listStyle(.sidebar)
            }
        }
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            if let file = selectedFile {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.path).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                        if let previous = file.previousPath {
                            Text(previous + " → " + file.path).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let diff {
                        Text("+\(diff.additions)").foregroundStyle(.green)
                        Text("−\(diff.deletions)").foregroundStyle(.red)
                    }
                }.font(.system(size: 11, design: .monospaced)).padding(14)
                Divider()
                if loadingDiff {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diffError {
                    placeholder(title: L10n.string("changes.unavailable"), detail: diffError)
                } else if let diff, !diff.lines.isEmpty {
                    if diff.truncated {
                        Text(L10n.string("changes.truncated")).font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.lines) { line in diffRow(line) }
                        }.frame(minWidth: 600, alignment: .leading).textSelection(.enabled).padding(.vertical, 8)
                    }
                } else {
                    placeholder(title: L10n.string("changes.no_text"), detail: L10n.string("changes.no_text_detail"))
                }
            } else {
                placeholder(title: L10n.string("changes.select_file"), detail: "")
            }
        }
    }

    private func diffRow(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing).padding(.trailing, 14)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk ? Color.accentColor : Color.primary)
                .fixedSize(horizontal: true, vertical: true)
            Spacer(minLength: 20)
        }
        .font(.system(size: 12, design: .monospaced)).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .addition ? Color.green.opacity(0.12) : line.kind == .deletion ? Color.red.opacity(0.12) : line.kind == .hunk ? Color.accentColor.opacity(0.07) : Color.clear)
    }

    private func placeholder(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled) }
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func loadSnapshot() async {
        loading = true
        error = nil
        let path = project.path
        do {
            let result = try await Task.detached(priority: .userInitiated) { try ProjectChangesService.snapshot(at: path) }.value
            guard !Task.isCancelled else { return }
            snapshot = result
            if !result.files.contains(where: { $0.path == selectedPath }) { selectedPath = result.files.first?.path }
            revision = UUID()
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            snapshot = nil
        }
        loading = false
    }

    @MainActor private func loadDiff() async {
        diff = nil
        diffError = nil
        loadingDiff = false
        guard let snapshot, let file = selectedFile else { return }
        loadingDiff = true
        do {
            let result = try await Task.detached(priority: .userInitiated) { try ProjectChangesService.diff(for: file, in: snapshot) }.value
            guard !Task.isCancelled else { return }
            diff = result
        } catch {
            guard !Task.isCancelled else { return }
            diffError = error.localizedDescription
        }
        loadingDiff = false
    }
}
