import SwiftUI

/// Workspace chrome shared by the conversation and its trailing review pane.
/// Keeping the content in a stable split-view child preserves editor focus/drafts.
struct ProjectChangesWorkspace<Content: View>: View {
    let project: PiProject?
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        HSplitView {
            content()
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            if isPresented, let project {
                ProjectChangesView(project: project) { isPresented = false }
                    .id(project.path)
                    .frame(minWidth: 340, idealWidth: 520, maxWidth: 800)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if project != nil {
                    Button { isPresented.toggle() } label: {
                        Label(L10n.string("changes.title"), systemImage: "sidebar.right")
                    }
                    .help(L10n.string("changes.title"))
                    .accessibilityIdentifier("project-changes-toggle")
                    .accessibilityAddTraits(isPresented ? .isSelected : [])
                    .tint(isPresented ? .accentColor : .primary)
                }
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
