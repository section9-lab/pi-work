import Foundation

struct ChangedFile: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let previousPath: String?
    let status: String

    var isUntracked: Bool { status == "??" }
    var badge: String {
        if isUntracked { return "U" }
        return String(status.first(where: { $0 != " " && $0 != "M" }) ?? "M")
    }
}

struct ProjectChangesSnapshot {
    let root: String
    let branch: String
    let hasHEAD: Bool
    let files: [ChangedFile]
}

struct DiffLine: Identifiable, Equatable {
    enum Kind { case context, addition, deletion, hunk, metadata }
    let id: Int
    let text: String
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
}

struct FileDiff {
    let lines: [DiffLine]
    let truncated: Bool
    var additions: Int { lines.filter { $0.kind == .addition }.count }
    var deletions: Int { lines.filter { $0.kind == .deletion }.count }

    static func parse(_ text: String, truncated: Bool = false) -> FileDiff {
        guard !text.isEmpty else { return FileDiff(lines: [], truncated: truncated) }
        var old = 0
        var new = 0
        var inHunk = false
        let expression = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        var lines: [DiffLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0) {
            let value = String(raw)
            var kind = DiffLine.Kind.metadata
            var oldNumber: Int?
            var newNumber: Int?
            if value.hasPrefix("diff --git ") {
                inHunk = false
            } else if let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
               let oldRange = Range(match.range(at: 1), in: value),
               let newRange = Range(match.range(at: 2), in: value) {
                old = Int(value[oldRange]) ?? 0
                new = Int(value[newRange]) ?? 0
                kind = .hunk
                inHunk = true
            } else if inHunk && value.hasPrefix("+") {
                kind = .addition; newNumber = new; new += 1
            } else if inHunk && value.hasPrefix("-") {
                kind = .deletion; oldNumber = old; old += 1
            } else if inHunk && value.hasPrefix(" ") {
                kind = .context; oldNumber = old; newNumber = new; old += 1; new += 1
            }
            lines.append(DiffLine(id: lines.count, text: value, kind: kind, oldNumber: oldNumber, newNumber: newNumber))
        }
        return FileDiff(lines: lines, truncated: truncated)
    }
}

/// Read-only Git operations. Arguments never pass through a shell; NUL-delimited
/// status preserves spaces, Unicode, tabs and newlines in filenames.
enum ProjectChangesService {
    struct GitFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func snapshot(at path: String) throws -> ProjectChangesSnapshot {
        let root = try run(["rev-parse", "--show-toplevel"], at: path).text.trimmingCharacters(in: .newlines)
        let branch = (try? run(["symbolic-ref", "--short", "HEAD"], at: root).text.trimmingCharacters(in: .newlines)) ?? "HEAD"
        let hasHEAD = (try? run(["rev-parse", "--verify", "HEAD"], at: root)) != nil
        let status = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root)
        guard !status.truncated else { throw GitFailure(message: L10n.string("changes.too_many_files")) }
        return ProjectChangesSnapshot(root: root, branch: branch, hasHEAD: hasHEAD, files: parseStatus(status.text))
    }

    static func parseStatus(_ text: String) -> [ChangedFile] {
        let entries = text.split(separator: "\0", omittingEmptySubsequences: true)
        var files: [ChangedFile] = []
        var index = 0
        while index < entries.count {
            let entry = String(entries[index])
            index += 1
            guard entry.count >= 4 else { continue }
            let status = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            var previous: String?
            if status.contains("R") || status.contains("C"), index < entries.count {
                previous = String(entries[index]); index += 1
            }
            files.append(ChangedFile(path: path, previousPath: previous, status: status))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func diff(for file: ChangedFile, in snapshot: ProjectChangesSnapshot) throws -> FileDiff {
        let result: Output
        if file.isUntracked {
            result = try run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", file.path], at: snapshot.root, allowed: [0, 1])
        } else {
            var arguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--submodule=short"]
            // Git recognizes the empty tree even in an unborn repository.
            // hash-object without -w calculates its ID without writing objects,
            // and also works with repositories using SHA-256 object IDs.
            let baseline = snapshot.hasHEAD ? "HEAD" : try run(["hash-object", "-t", "tree", "--stdin"], at: snapshot.root).text.trimmingCharacters(in: .newlines)
            arguments.append(baseline)
            arguments += ["--", file.path]
            if let previous = file.previousPath { arguments.append(previous) }
            result = try run(arguments, at: snapshot.root)
        }
        return FileDiff.parse(result.text, truncated: result.truncated)
    }

    private struct Output { let text: String; let truncated: Bool }

    private static func run(_ arguments: [String], at path: String, allowed: Set<Int32> = [0]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--literal-pathspecs", "-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain continuously even after the display cap, so a large diff cannot
        // deadlock a full pipe or retain unbounded output in memory.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer { timeout.cancel() }
        let cap = 2 * 1024 * 1024
        var data = Data()
        var truncated = false
        while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            let remaining = cap - data.count
            data.append(chunk.prefix(remaining))
            if chunk.count > remaining { truncated = true }
        }
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard allowed.contains(process.terminationStatus) else {
            throw GitFailure(message: String(text.prefix(2000)))
        }
        return Output(text: text, truncated: truncated)
    }
}
