import CoreFoundation
import Foundation

enum MCPTransport: String, CaseIterable, Identifiable {
    case stdio, http
    var id: String { rawValue }
    var title: String { self == .stdio ? "STDIO" : "Streamable HTTP" }
}

struct MCPKeyValue: Identifiable, Equatable {
    let id = UUID()
    var key = ""
    var value = ""
}

enum MCPDraftError: String, LocalizedError {
    case invalidJSON, invalidName, invalidURL, invalidCommand, invalidTimeout
    case duplicateKey, missingKey, invalidPairs, unsupportedTransport
    var errorDescription: String? { L10n.string("mcp.validation.\(rawValue)") }
}

/// UI fields are typed; Foundation's JSON boundary preserves upstream options
/// the form does not own (OAuth, exposure, enabled state and per-tool settings).
struct MCPServerDraft {
    var transport: MCPTransport = .stdio
    var name = ""
    var commandLine = ""
    var url = ""
    var environment = [MCPKeyValue()]
    var headers = [MCPKeyValue()]
    var timeout = ""
    var workingDirectory = ""
    private var original: [String: Any] = ["exposure": "deferred"]

    init(server: MCPServer? = nil) {
        guard let server else { return }
        name = server.name
        // Invalid legacy configurations remain editable in the JSON editor.
        try? applyJSON(server.configurationJSON)
    }

    mutating func applyJSON(_ json: String) throws {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPDraftError.invalidJSON
        }
        if let type = object["type"] as? String, !["stdio", "http"].contains(type) {
            throw MCPDraftError.unsupportedTransport
        }
        let hasURL = object["url"] is String
        let hasCommand = object["command"] is String
        guard hasURL != hasCommand else { throw MCPDraftError.invalidJSON }
        if let args = object["args"], !(args is [String]) { throw MCPDraftError.invalidJSON }
        for key in ["headers", "env"] {
            if let values = object[key], !(values is [String: String]) { throw MCPDraftError.invalidJSON }
        }
        if let timeout = object["timeout"] {
            guard let number = timeout as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw MCPDraftError.invalidTimeout
            }
        }
        original = object
        transport = hasURL ? .http : .stdio
        url = object["url"] as? String ?? ""
        commandLine = ([object["command"] as? String].compactMap { $0 } + (object["args"] as? [String] ?? []))
            .map(MCPCommandLine.quote).joined(separator: " ")
        environment = Self.pairs(object["env"] as? [String: String] ?? [:])
        headers = Self.pairs(object["headers"] as? [String: String] ?? [:])
        timeout = (object["timeout"] as? NSNumber)?.stringValue ?? ""
        workingDirectory = object["cwd"] as? String ?? ""
    }

    var validationError: MCPDraftError? {
        do { _ = try configurationJSON(); return nil }
        catch let error as MCPDraftError { return error }
        catch { return .invalidJSON }
    }

    func configurationJSON(validate: Bool = true) throws -> String {
        if validate, name.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
            throw MCPDraftError.invalidName
        }
        var object = original
        if transport == .http {
            let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if validate, MCPStore.webURL(address) == nil { throw MCPDraftError.invalidURL }
            for key in ["command", "args", "env", "cwd"] { object.removeValue(forKey: key) }
            object["type"] = "http"
            object["url"] = address
            object["headers"] = try Self.dictionary(headers, caseInsensitive: true)
        } else {
            let command = try MCPCommandLine.parse(commandLine)
            if validate, command.first?.isEmpty != false { throw MCPDraftError.invalidCommand }
            for key in ["url", "headers", "oauth", "auth"] { object.removeValue(forKey: key) }
            object["type"] = "stdio"
            object["command"] = command.first ?? ""
            object["args"] = Array(command.dropFirst())
            object["env"] = try Self.dictionary(environment)
            let cwd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            object["cwd"] = cwd.isEmpty ? nil : cwd
        }
        let seconds = timeout.trimmingCharacters(in: .whitespacesAndNewlines)
        if seconds.isEmpty {
            object.removeValue(forKey: "timeout")
        } else {
            guard let value = Double(seconds), value.isFinite, value > 0 else { throw MCPDraftError.invalidTimeout }
            object["timeout"] = value
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func pastedPairs(_ text: String, headers: Bool) throws -> [MCPKeyValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPDraftError.invalidPairs }
        if trimmed.hasPrefix("{") {
            guard let values = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: String] else {
                throw MCPDraftError.invalidPairs
            }
            return pairs(values)
        }
        let parsed = try trimmed.components(separatedBy: .newlines).compactMap { line -> MCPKeyValue? in
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            let separator = headers ? line.firstIndex(of: ":") ?? line.firstIndex(of: "=") : line.firstIndex(of: "=")
            guard let separator else { throw MCPDraftError.invalidPairs }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if !headers, value.count >= 2,
               (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            return MCPKeyValue(key: key, value: value)
        }
        guard !parsed.isEmpty else { throw MCPDraftError.invalidPairs }
        _ = try dictionary(parsed, caseInsensitive: headers)
        return parsed
    }

    static func dictionary(_ pairs: [MCPKeyValue], caseInsensitive: Bool = false) throws -> [String: String] {
        var result: [String: String] = [:]
        var seen = Set<String>()
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty && pair.value.isEmpty { continue }
            guard !key.isEmpty else { throw MCPDraftError.missingKey }
            guard seen.insert(caseInsensitive ? key.lowercased() : key).inserted else { throw MCPDraftError.duplicateKey }
            result[key] = pair.value
        }
        return result
    }

    private static func pairs(_ values: [String: String]) -> [MCPKeyValue] {
        values.isEmpty ? [MCPKeyValue()] : values.keys.sorted().map { MCPKeyValue(key: $0, value: values[$0] ?? "") }
    }
}

/// Parse command arguments without starting a shell, expanding variables or
/// interpreting operators. Quoting round-trips spaces, apostrophes and empty args.
enum MCPCommandLine {
    static func parse(_ command: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var started = false
        for character in command {
            if escaping {
                current.append(character); escaping = false; started = true
            } else if character == "\\", quote != "'" {
                escaping = true; started = true
            } else if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character; started = true
            } else if character.isWhitespace {
                if started { arguments.append(current); current = ""; started = false }
            } else {
                current.append(character); started = true
            }
        }
        guard quote == nil, !escaping else { throw MCPDraftError.invalidCommand }
        if started { arguments.append(current) }
        return arguments
    }

    static func quote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        if argument.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
