import XCTest
@testable import PiWork

final class ProjectChangesTests: XCTestCase {
    func testReviewIsWorkspaceToolbarAndTrailingPaneNotSidebarOrSessionSheet() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let content = try source("PiWork/App/Root/ContentView.swift")
        let sidebar = try source("PiWork/Features/Sidebar/Views/SidebarView.swift")
        let chat = try source("PiWork/Features/Chat/Views/ChatView.swift")
        let panel = try source("PiWork/Features/Changes/ProjectChangesView.swift")
        XCTAssertTrue(content.contains("ProjectChangesWorkspace(project: changesProject"))
        XCTAssertTrue(panel.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertTrue(panel.contains("project-changes-toggle"))
        XCTAssertTrue(panel.contains("HSplitView"))
        XCTAssertTrue(panel.contains("ProjectChangesView(project: project)"))
        XCTAssertTrue(panel.contains(".id(project.path)"))
        XCTAssertFalse(sidebar.contains("changesProject"))
        XCTAssertFalse(sidebar.contains("changes.title"))
        XCTAssertFalse(chat.contains("ProjectChangesView"))
        XCTAssertTrue(panel.contains("VSplitView"))
        XCTAssertTrue(panel.contains("Button(action: onClose)"))
        XCTAssertFalse(panel.contains("dismiss()"))
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
    }
}
