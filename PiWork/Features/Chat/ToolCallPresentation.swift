import Combine
import Foundation

extension SessionToolRecord {
    var durationText: String? {
        guard case .number(let milliseconds) = rawOutput?.objectValue?["_piWork"]?.objectValue?["durationMs"],
              milliseconds.isFinite, milliseconds >= 0 else { return nil }
        return milliseconds < 1000
            ? String(format: "%.0fms", milliseconds)
            : String(format: "%.2fs", milliseconds / 1000)
    }
}

/// Parsed input presentation. Full formatting is lazy, so collapsed write/edit
/// rows do not allocate another formatted copy of a large input.
final class ToolCallPresentation {
    let isBash: Bool
    let title: String
    let iconName: String
    let summary: String
    let writtenLineCount: Int?
    private let name: String
    private let input: AgentHostJSONValue?
    private let fallbackSummary: String
    private(set) lazy var formattedInput: String = makeFormattedInput()

    init(tool: SessionToolRecord) {
        name = tool.name.lowercased()
        fallbackSummary = tool.summary
        isBash = name == "bash"
        title = tool.name.replacingOccurrences(of: "_", with: " ")
        switch name {
        case "read": iconName = "book"
        case "bash": iconName = "terminal"
        case "write": iconName = "square.and.pencil"
        case "edit", "editor": iconName = "highlighter"
        case "grep", "find": iconName = "magnifyingglass"
        case "ls": iconName = "folder"
        case "web_search": iconName = "magnifyingglass"
        case "web_fetch", "fetch_content": iconName = "globe"
        default: iconName = "wrench.and.screwdriver"
        }
        input = tool.rawInput ?? tool.summary.data(using: .utf8).flatMap {
            try? JSONDecoder().decode(AgentHostJSONValue.self, from: $0)
        }
        let object = input?.objectValue
        if name == "write", let content = object?["content"]?.stringValue {
            // Count without allocating a second copy or an array of lines.
            let newlines = content.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            writtenLineCount = newlines + (content.isEmpty || content.utf8.last == 0x0A ? 0 : 1)
        } else {
            writtenLineCount = nil
        }
        summary = ["path", "command", "query", "url", "pattern"]
            .compactMap { object?[$0]?.stringValue }
            .first(where: { !$0.isEmpty }) ?? tool.summary
    }

    private func makeFormattedInput() -> String {
        let object = input?.objectValue
        if isBash, let command = object?["command"]?.stringValue {
            return command
        } else if name == "read", let object, let path = object["path"]?.stringValue {
            let range = ["offset", "limit"].compactMap { key -> String? in
                guard let value = object[key]?.intValue else { return nil }
                return "\(key): \(value)"
            }
            return ([path] + range).joined(separator: "  ·  ")
        } else if let object, !object.isEmpty {
            let preferredKeys = ["path", "command", "query", "url", "pattern", "content"]
            let keys = preferredKeys.filter { object[$0] != nil }
                + object.keys.filter { !preferredKeys.contains($0) }.sorted()
            return keys.compactMap { key -> String? in
                guard let value = object[key] else { return nil }
                let encoded = try? JSONSerialization.data(withJSONObject: value.foundationValue,
                    options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                let text = value.stringValue ?? encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                return keys.count == 1 ? text : "\(key): \(text)"
            }.joined(separator: "\n")
        } else {
            return input?.stringValue ?? input?.prettyPrinted ?? fallbackSummary
        }
    }
}

/// One entry per mounted row, rather than a global cache of growing payloads.
@MainActor
final class ToolInputPresentationCache: ObservableObject {
    final class Value {
        let call: ToolCallPresentation
        let edit: ToolEditPresentation?
        init(tool: SessionToolRecord) {
            call = ToolCallPresentation(tool: tool)
            edit = ToolEditPresentation(name: tool.name, rawInput: tool.rawInput, summary: tool.summary)
        }
    }
    private var name: String?
    private var summary: String?
    private var input: AgentHostJSONValue?
    private var cached: Value?

    func value(for tool: SessionToolRecord) -> Value {
        if let cached, name == tool.name, summary == tool.summary, input == tool.rawInput { return cached }
        let value = Value(tool: tool)
        name = tool.name; summary = tool.summary; input = tool.rawInput; cached = value
        return value
    }
}

@MainActor
final class ToolDiffPresentationCache: ObservableObject {
    private var oldText: String?
    private var newText: String?
    private var cached: ToolDiffPresentation?

    func value(oldText: String?, newText: String) -> ToolDiffPresentation {
        if let cached, self.oldText == oldText, self.newText == newText { return cached }
        let value = ToolDiffPresentation(oldText: oldText, newText: newText)
        self.oldText = oldText; self.newText = newText; cached = value
        return value
    }
}
