import Foundation

/// A registry entry, not an installed server. Public recipes are untrusted input:
/// browsing never executes them, and the editor reviews every connection first.
struct MCPMarketPreset: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let publisher: String
    var summary = ""
    let connection: Connection
    var requiresLogin = false
    let documentationURL: String
    var iconURLs: [URL] = []
    var version = ""
    var environment: [String: String] = [:]
    var headers: [String: String] = [:]
    var setupNotes: [String] = []

    enum Connection: Codable, Equatable, Sendable {
        case http(String)
        case stdio(command: String, arguments: [String])
        case unsupported
    }

    var suggestedName: String {
        let tail = id.split(separator: "/").last.map(String.init) ?? id
        let cleaned = tail.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        return cleaned.isEmpty ? "mcp-server" : String(cleaned.prefix(80))
    }

    var isLocal: Bool {
        if case .stdio = connection { return true }
        return false
    }

    var isRemote: Bool {
        if case .http = connection { return true }
        return false
    }

    var isInstallable: Bool { connection != .unsupported }
    var canQuickAdd: Bool { isInstallable && !isLocal && setupNotes.isEmpty && headers.isEmpty }

    var transportLabel: String {
        switch connection {
        case .http: return "HTTP"
        case .stdio(let command, _): return command
        case .unsupported: return "MCP"
        }
    }

    func matches(_ server: MCPServer) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(server.configurationJSON.utf8)) as? [String: Any] else { return false }
        switch connection {
        case .http(let address):
            guard let actual = object["url"] as? String else { return false }
            return Self.endpoint(actual) == Self.endpoint(address)
        case .stdio(let command, let arguments):
            return object["command"] as? String == command && object["args"] as? [String] == arguments
        case .unsupported: return false
        }
    }

    func draft(name: String? = nil) -> MCPServerDraft {
        var draft = MCPServerDraft()
        draft.name = name ?? suggestedName
        switch connection {
        case .http(let address):
            draft.transport = .http
            draft.url = address
            draft.headers = headers.keys.sorted().map { MCPKeyValue(key: $0, value: headers[$0] ?? "") }
        case .stdio(let command, let arguments):
            draft.commandLine = ([command] + arguments).map(MCPCommandLine.quote).joined(separator: " ")
            draft.environment = environment.keys.sorted().map { MCPKeyValue(key: $0, value: environment[$0] ?? "") }
        case .unsupported: break
        }
        return draft
    }

    func matchesSearch(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [id, name, publisher, summary].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func endpoint(_ address: String) -> String? {
        guard var parts = URLComponents(string: address), parts.host != nil else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        // Query parameters can identify different tenants or projects. Preserve
        // them rather than marking an unrelated server as already installed.
        parts.queryItems = parts.queryItems?.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string
    }
}
