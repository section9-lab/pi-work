import Foundation

/// Converts complete edit arguments into previews, leaving incomplete/unknown inputs on the JSON fallback.
struct ToolEditPresentation {
    struct Change: Equatable {
        let path: String
        let oldText: String
        let newText: String
    }

    let changes: [Change]

    let diffs: [ToolDiffPresentation]
    let diffSummary: (additions: Int, deletions: Int)

    init?(name: String, rawInput: AgentHostJSONValue?, summary: String) {
        guard ["edit", "editor"].contains(name.lowercased()) else { return nil }
        let input = rawInput ?? summary.data(using: .utf8).flatMap {
            try? JSONDecoder().decode(AgentHostJSONValue.self, from: $0)
        }
        guard let object = input?.objectValue,
              let path = object["path"]?.stringValue, !path.isEmpty else { return nil }
        let entries: [AgentHostJSONValue]
        if let edits = object["edits"] {
            guard let array = edits.arrayValue, !array.isEmpty else { return nil }
            entries = array
        } else {
            entries = [.object(object)]
        }
        var changes: [Change] = []
        for entry in entries {
            guard let edit = entry.objectValue,
                  let oldText = edit["oldText"]?.stringValue,
                  let newText = edit["newText"]?.stringValue else { return nil }
            changes.append(Change(path: path, oldText: oldText, newText: newText))
        }
        self.changes = changes
        diffs = changes.map { ToolDiffPresentation(oldText: $0.oldText, newText: $0.newText) }
        diffSummary = diffs.reduce(into: (additions: 0, deletions: 0)) { totals, diff in
            totals.additions += diff.additions
            totals.deletions += diff.deletions
        }
    }
}
