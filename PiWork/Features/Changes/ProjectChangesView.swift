import SwiftUI

/// Project-session chrome lives inside the detail column, not NSToolbar. Adding
/// a global toolbar item changes NavigationSplitView's sidebar/titlebar layout.
struct ProjectChangesWorkspace<Content: View>: View {
    let project: PiProject?
    var sessionTitle: String? = nil
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content
    @State private var showsProjectMenu = false
    @State private var preferredReviewWidth: CGFloat = 420
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let layout = ProjectReviewLayout(
                availableWidth: geometry.size.width,
                preferredWidth: preferredReviewWidth,
                isPresented: isPresented && project != nil
            )
            VStack(spacing: 0) {
                if let project { sessionHeader(project) }
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
            }
        }
        .onChange(of: project?.path) { _ in showsProjectMenu = false }
    }

    private func sessionHeader(_ project: PiProject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(sessionTitle ?? project.name)
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 12)
            Button { showsProjectMenu.toggle() } label: {
                ProjectSessionMenuIcon().frame(width: 32, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(showsProjectMenu || isPresented ? 0.08 : 0))
                    )
            }
            .buttonStyle(.plain)
            .help(L10n.string("changes.project_menu"))
            .accessibilityLabel(L10n.string("changes.project_menu"))
            .accessibilityIdentifier("project-session-menu-toggle")
            .background(WindowTitlebarControlRegion())
            .popover(isPresented: $showsProjectMenu, arrowEdge: .top) {
                ProjectSessionReviewMenu(project: project) {
                    showsProjectMenu = false
                    isPresented.toggle()
                }
                .id(project.path)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .accessibilityIdentifier("project-session-header")
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
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(project.name).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let snapshot {
                    Text(snapshot.branch)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.primary, in: Capsule())
                        .foregroundStyle(AppPalette.raisedSurface)
                }
            }
            Button(action: onReview) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text(L10n.string("changes.title")).fontWeight(.medium)
                    Spacer()
                    if let snapshot { Text(String(snapshot.files.count)).foregroundStyle(.secondary) }
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                }
                .padding(10).contentShape(Rectangle())
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project-changes-toggle")
            if failed {
                Text(L10n.string("changes.unavailable")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(width: 300)
        .accessibilityIdentifier("project-session-menu")
        .task(id: project.path) {
            do {
                let path = project.path
                let result = try await Task.detached(priority: .userInitiated) {
                    try ProjectChangesService.snapshot(at: path)
                }.value
                guard !Task.isCancelled else { return }
                snapshot = result
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
