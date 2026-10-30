import Foundation

/// Tool edits contain snippets, not reliable absolute file positions.
struct ToolDiffPresentation {
    enum Kind: Equatable { case context, removed, added }
    struct Line {
        let kind: Kind
        let text: String
    }
    let lines: [Line]
    var additions: Int { lines.filter { $0.kind == .added }.count }
    var deletions: Int { lines.filter { $0.kind == .removed }.count }

    init(oldText: String?, newText: String) {
        func split(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return lines
        }
        let old = split(oldText ?? "")
        let new = split(newText)
        // Avoid expensive diffing for very large tool payloads.
        guard old.count + new.count <= 4000 else {
            lines = old.map { Line(kind: .removed, text: $0) }
                + new.map { Line(kind: .added, text: $0) }
            return
        }
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var added = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var result: [Line] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                result.append(Line(kind: .removed, text: old[i]))
                i += 1
            } else if j < new.count, added.contains(j) {
                result.append(Line(kind: .added, text: new[j]))
                j += 1
            } else if i < old.count, j < new.count {
                result.append(Line(kind: .context, text: new[j]))
                i += 1
                j += 1
            } else { break }
        }
        lines = result
    }
}
