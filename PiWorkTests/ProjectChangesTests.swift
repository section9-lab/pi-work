import AppKit
import SwiftUI
import XCTest
@testable import PiWork

final class ProjectChangesTests: XCTestCase {
    func testReviewUsesUpperRightOverlayWithoutTitleRowOrSystemPopover() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let content = try source("PiWork/App/Root/ContentView.swift")
        let sidebar = try source("PiWork/Features/Sidebar/Views/SidebarView.swift")
        let chat = try source("PiWork/Features/Chat/Views/ChatView.swift")
        let panel = try source("PiWork/Features/Changes/ProjectChangesView.swift")
        XCTAssertTrue(content.contains("ProjectChangesWorkspace(project: changesProject"))
        XCTAssertFalse(panel.contains("project-session-header"))
        XCTAssertFalse(panel.contains("sessionTitle"))
        XCTAssertTrue(content.contains("ProjectSessionMenuOverlay(project: project"))
        XCTAssertTrue(panel.contains(".padding(.top, 10)"))
        XCTAssertTrue(panel.contains("project-session-menu-toggle"))
        XCTAssertTrue(panel.contains("project-changes-toggle"))
        XCTAssertFalse(panel.contains(".popover("))
        XCTAssertTrue(panel.contains("showsPointer: false"))
        XCTAssertTrue(panel.contains("InWindowFloatingPanel("))
        XCTAssertFalse(panel.contains(".toolbar"))
        XCTAssertFalse(panel.contains("ToolbarItem"))
        XCTAssertFalse(panel.contains("HSplitView"))
        XCTAssertFalse(content.contains("? 1100 : 900"))
        XCTAssertTrue(content.contains(".frame(minWidth: 900, minHeight: 600)"))
        XCTAssertTrue(panel.contains("ProjectChangesView(project: project)"))
        XCTAssertTrue(panel.contains(".id(project.path)"))
        XCTAssertFalse(sidebar.contains("changesProject"))
        XCTAssertFalse(sidebar.contains("changes.title"))
        XCTAssertFalse(chat.contains("ProjectChangesView"))
        XCTAssertTrue(panel.contains("VSplitView"))
        XCTAssertTrue(panel.contains("Button(action: onClose)"))
        XCTAssertFalse(panel.contains("dismiss()"))
    }

    func testReviewLayoutNeverExceedsDetailWidthOrResizesSidebar() {
        for width: CGFloat in [0, 180, 480, 640, 700, 701, 900, 1200] {
            for preferred: CGFloat in [200, 420, 900] {
                let closed = ProjectReviewLayout(availableWidth: width, preferredWidth: preferred, isPresented: false)
                XCTAssertEqual(closed.contentWidth, width)
                XCTAssertEqual(closed.reviewWidth, 0)
                let open = ProjectReviewLayout(availableWidth: width, preferredWidth: preferred, isPresented: true)
                XCTAssertLessThanOrEqual(open.contentWidth, width)
                XCTAssertLessThanOrEqual(open.reviewWidth, width)
                XCTAssertGreaterThanOrEqual(open.contentWidth, 0)
                if open.overlaysContent {
                    XCTAssertEqual(open.contentWidth, width)
                } else {
                    XCTAssertEqual(open.contentWidth + open.reviewWidth + 1, width)
                    XCTAssertGreaterThanOrEqual(open.contentWidth, 400)
                }
            }
        }
    }

    @MainActor
    func testOpeningReviewPreservesNativeSidebarWindowAndConversationIdentity() async throws {
        let state = ProjectReviewLayoutHarness()
        let host = NSHostingView(rootView: ProjectReviewLayoutHarnessView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for width: CGFloat in [900, 1400] {
            state.isPresented = false
            window.setContentSize(NSSize(width: width, height: 680))
            try await Task.sleep(nanoseconds: 300_000_000)
            host.layoutSubtreeIfNeeded()
            let sidebar = state.sidebarFrame
            let frame = window.frame
            let minimum = window.contentMinSize
            let appearances = state.contentAppearances
            XCTAssertGreaterThan(sidebar.width, 0)
            func findControl(in view: NSView) -> NSView? {
                if String(describing: type(of: view)).contains("WindowTitlebarControlView") { return view }
                return view.subviews.lazy.compactMap { findControl(in: $0) }.first
            }
            let control = try XCTUnwrap(findControl(in: host))
            let controlFrame = control.convert(control.bounds, to: host)
            XCTAssertLessThanOrEqual(controlFrame.maxY, 52, "Menu must be in the top window chrome, not a title row")
            XCTAssertGreaterThan(controlFrame.midX, host.bounds.width - 60)
            state.isPresented = true
            try await Task.sleep(nanoseconds: 300_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(state.sidebarFrame, sidebar, "Review must not move or resize the left menu")
            XCTAssertEqual(window.frame, frame, "Review must not grow the window off-screen")
            XCTAssertEqual(window.contentMinSize, minimum)
            XCTAssertEqual(state.contentAppearances, appearances, "Conversation/draft identity must be stable")
        }
    }

    @MainActor
    func testSessionMenuControlIsExcludedFromTitlebarDragging() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 52),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Color.clear
            .overlay(alignment: .topTrailing) {
                Button("Project") {}.frame(width: 32, height: 30)
                    .background(WindowTitlebarControlRegion())
            }
            .overlay { WindowTitlebarDragRegion() })
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 52)
        host.layoutSubtreeIfNeeded()
        func find(_ name: String, in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains(name) { return view }
            return view.subviews.lazy.compactMap { find(name, in: $0) }.first
        }
        let drag = try XCTUnwrap(find("WindowTitlebarDragView", in: host))
        let control = try XCTUnwrap(find("WindowTitlebarControlView", in: host))
        XCTAssertGreaterThan(control.bounds.width, 0)
        let parent = try XCTUnwrap(drag.superview)
        for origin in [NSPoint.zero, NSPoint(x: 13, y: 9)] {
            drag.setFrameOrigin(origin)
            for x in [control.bounds.minX + 2, control.bounds.midX, control.bounds.maxX - 2] {
                for y in [control.bounds.minY + 2, control.bounds.midY, control.bounds.maxY - 2] {
                    let point = control.convert(NSPoint(x: x, y: y), to: parent)
                    XCTAssertNil(drag.hitTest(point), "Entire project menu must be excluded, even with offset titlebar bounds")
                }
            }
            let emptyPoint = drag.convert(NSPoint(x: 8, y: 8), to: parent)
            XCTAssertNotNil(drag.hitTest(emptyPoint), "Empty titlebar must remain draggable")
        }
    }

    func testStatusPreservesUnusualPathsAndRenamePairs() {
        let files = ProjectChangesService.parseStatus(" M folder/a b.swift\0R  新名.swift\0old.swift\0?? line\nbreak.txt\0 D removed.txt\0")
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(files.first { $0.path == "新名.swift" }?.previousPath, "old.swift")
        XCTAssertEqual(files.first { $0.path == "folder/a b.swift" }?.badge, "M")
        XCTAssertEqual(files.first { $0.path == "removed.txt" }?.badge, "D")
        XCTAssertTrue(files.contains { $0.path == "line\nbreak.txt" && $0.isUntracked })
    }

    func testDiffLineNumbersAndHeaderPrefixes() {
        let diff = FileDiff.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -4,2 +4,3 @@ function\n context\n-old\n+new\n+++literal\n\\ No newline at end of file\n")
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
        let context = diff.lines.first { $0.kind == .context }
        XCTAssertEqual(context?.oldNumber, 4)
        XCTAssertEqual(context?.newNumber, 4)
        let added = diff.lines.filter { $0.kind == .addition }
        XCTAssertEqual(added.map(\.newNumber), [5, 6])
        XCTAssertEqual(added.last?.text, "+++literal")
        XCTAssertNil(diff.lines.last?.newNumber)
        XCTAssertTrue(FileDiff.parse("").lines.isEmpty)
    }

    func testRepositoryIncludesStagedUnstagedUntrackedDeletedAndRenamed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = root
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        func put(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try git("init")
        try git("config", "user.name", "Changes Test")
        try git("config", "user.email", "changes@example.test")
        try put("a file.txt", "one\ntwo\n")
        try put("delete.txt", "delete\n")
        try put("old.txt", "rename\n")
        try git("add", ".")
        try git("commit", "-m", "initial")
        try put("a file.txt", "one\nstaged\n")
        try git("add", "a file.txt")
        try put("a file.txt", "one\nstaged\nworking\n")
        try put("未跟踪.txt", "new\n")
        try put("binary.dat", "\0binary")
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
        try git("mv", "old.txt", "new.txt")
        let snapshot = try ProjectChangesService.snapshot(at: root.path)
        XCTAssertEqual(snapshot.files.count, 5)
        XCTAssertEqual(ProjectChangesService.summary(in: snapshot), .init(additions: 3, deletions: 2))
        let changed = try XCTUnwrap(snapshot.files.first { $0.path == "a file.txt" })
        XCTAssertEqual(changed.status, "MM")
        let diff = try ProjectChangesService.diff(for: changed, in: snapshot)
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
        let renamed = try XCTUnwrap(snapshot.files.first { $0.path == "new.txt" })
        XCTAssertEqual(renamed.previousPath, "old.txt")
        XCTAssertTrue(try ProjectChangesService.diff(for: renamed, in: snapshot).lines.contains { $0.text.contains("rename from") })
        let untracked = try XCTUnwrap(snapshot.files.first { $0.path == "未跟踪.txt" })
        XCTAssertEqual(try ProjectChangesService.diff(for: untracked, in: snapshot).additions, 1)
        let binary = try XCTUnwrap(snapshot.files.first { $0.path == "binary.dat" })
        XCTAssertEqual(try ProjectChangesService.diff(for: binary, in: snapshot).additions, 0)
        let deleted = try XCTUnwrap(snapshot.files.first { $0.path == "delete.txt" })
        XCTAssertEqual(try ProjectChangesService.diff(for: deleted, in: snapshot).deletions, 1)
    }

    func testMultiplePatchHeadersDoNotCountAsChangedCode() {
        let diff = FileDiff.parse("diff --git a/old b/old\n--- a/old\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\ndiff --git a/new b/new\n--- /dev/null\n+++ b/new\n@@ -0,0 +1 @@\n+new\n")
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.lines.first { $0.text == "+new" }?.newNumber, 1)
    }

    func testUnbornRepositoryAndNonRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ProjectChangesService.snapshot(at: root.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try "first\n".write(to: root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        let snapshot = try ProjectChangesService.snapshot(at: root.path)
        XCTAssertFalse(snapshot.hasHEAD)
        let file = try XCTUnwrap(snapshot.files.first)
        XCTAssertEqual(try ProjectChangesService.diff(for: file, in: snapshot).additions, 1)
        XCTAssertEqual(ProjectChangesService.summary(in: snapshot), .init(additions: 1, deletions: 0))
    }
}

@MainActor
private final class ProjectReviewLayoutHarness: ObservableObject {
    @Published var isPresented = false
    var sidebarFrame = CGRect.zero
    var contentAppearances = 0
}

private struct ProjectReviewSidebarFrameKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

private struct ProjectReviewLayoutHarnessView: View {
    @ObservedObject var state: ProjectReviewLayoutHarness
    private let project = PiProject(name: "Layout Test", path: NSTemporaryDirectory())

    var body: some View {
        NavigationSplitView {
            Text("Sidebar").frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ProjectReviewSidebarFrameKey.self,
                        value: geometry.frame(in: .named("review-layout-test")))
                })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
        } detail: {
            ProjectChangesWorkspace(project: project, isPresented: $state.isPresented) {
                Text("Conversation and draft")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { state.contentAppearances += 1 }
            }
        }
        .overlayPreferenceValue(ProjectReviewControlInsetKey.self) { inset in
            ProjectSessionMenuOverlay(project: project, reviewTrailingInset: inset,
                isReviewPresented: $state.isPresented)
        }
        .coordinateSpace(name: "review-layout-test")
        .onPreferenceChange(ProjectReviewSidebarFrameKey.self) {
            if let frame = $0 { state.sidebarFrame = frame }
        }
    }
}
