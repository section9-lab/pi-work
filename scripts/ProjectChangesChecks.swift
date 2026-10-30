import Foundation

@main
struct ProjectChangesChecks {
    static func main() throws {
        for width: CGFloat in [0, 180, 480, 640, 700, 701, 900, 1200] {
            for preferred: CGFloat in [200, 420, 900] {
                let closed = ProjectReviewLayout(availableWidth: width, preferredWidth: preferred, isPresented: false)
                precondition(closed.contentWidth == width && closed.reviewWidth == 0)
                let open = ProjectReviewLayout(availableWidth: width, preferredWidth: preferred, isPresented: true)
                precondition(open.contentWidth >= 0 && open.contentWidth <= width && open.reviewWidth <= width)
                if open.overlaysContent { precondition(open.contentWidth == width) }
                else { precondition(open.contentWidth + open.reviewWidth + 1 == width && open.contentWidth >= 400) }
            }
        }
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
            precondition(process.terminationStatus == 0)
        }
        func put(_ name: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        do {
            _ = try ProjectChangesService.snapshot(at: root.path)
            fatalError("Non-repository should fail")
        } catch { }
        try git("init")
        try git("config", "user.name", "Test")
        try git("config", "user.email", "test@example.test")
        try put("a file.txt", "one\ntwo\n")
        var snapshot = try ProjectChangesService.snapshot(at: root.path)
        precondition(!snapshot.hasHEAD)
        var diff = try ProjectChangesService.diff(for: snapshot.files[0], in: snapshot)
        precondition(diff.additions == 2)
        try git("add", ".")
        snapshot = try ProjectChangesService.snapshot(at: root.path)
        diff = try ProjectChangesService.diff(for: snapshot.files[0], in: snapshot)
        precondition(diff.additions == 2)
        try put("delete.txt", "delete\n")
        try put("old.txt", "rename\n")
        try git("add", ".")
        try git("commit", "-m", "initial")
        snapshot = try ProjectChangesService.snapshot(at: root.path)
        precondition(snapshot.files.isEmpty)
        precondition(ProjectChangesService.summary(in: snapshot) == .init(additions: 0, deletions: 0))
        try put("a file.txt", "one\nstaged\n")
        try git("add", "a file.txt")
        try put("a file.txt", "one\nstaged\nworking\n")
        try put("未跟踪.txt", "new\n")
        try put("binary.dat", "\0binary")
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
        try git("mv", "old.txt", "new.txt")
        snapshot = try ProjectChangesService.snapshot(at: root.path)
        precondition(snapshot.files.count == 5)
        precondition(ProjectChangesService.summary(in: snapshot) == .init(additions: 3, deletions: 2))
        for file in snapshot.files {
            diff = try ProjectChangesService.diff(for: file, in: snapshot)
            switch file.path {
            case "a file.txt": precondition(file.status == "MM" && diff.additions == 2 && diff.deletions == 1)
            case "delete.txt": precondition(diff.deletions == 1)
            case "new.txt": precondition(file.previousPath == "old.txt" && diff.lines.contains { $0.text.contains("rename from") })
            case "未跟踪.txt": precondition(diff.additions == 1)
            case "binary.dat": precondition(diff.additions == 0 && diff.lines.contains { $0.text.contains("Binary") })
            default: fatalError("Unexpected file")
            }
        }
        let parsed = ProjectChangesService.parseStatus(" M folder/a b.swift\0R  新名.swift\0old.swift\0?? line\nbreak.txt\0")
        precondition(parsed.count == 3 && parsed.contains { $0.path == "line\nbreak.txt" })
        diff = FileDiff.parse("--- a/a\n+++ b/a\n@@ -4,2 +4,3 @@\n context\n-old\n+new\n+++literal\n")
        precondition(diff.additions == 2 && diff.deletions == 1)
        precondition(diff.lines.filter { $0.kind == .addition }.map(\.newNumber) == [5, 6])
        precondition(FileDiff.parse("").lines.isEmpty)
        diff = FileDiff.parse("diff --git a/old b/old\n--- a/old\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\ndiff --git a/new b/new\n--- /dev/null\n+++ b/new\n@@ -0,0 +1 @@\n+new\n")
        precondition(diff.additions == 1 && diff.deletions == 1)
        print("Project changes checks passed: clean, staged + unstaged, untracked, rename, deletion, binary, unborn, invalid repository, path and line parsing, compact/wide review layouts.")
    }
}
