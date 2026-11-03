import Foundation

/// Curated connection recipes, not installed servers. Browsing never executes
/// commands, contacts providers or grants Chat/read-only permissions.
struct MCPMarketPreset: Identifiable {
    let id: String
    let name: String
    let publisher: String
    let symbol: String
    let connection: Connection
    var requiresLogin = false
    let documentationURL: String

    enum Connection {
        case http(String)
        case stdio(command: String, arguments: [String])
    }

    var summary: String { L10n.string("mcp.market.\(id).summary") }
    var isLocal: Bool {
        if case .stdio = connection { return true }
        return false
    }

    func matches(_ server: MCPServer) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(server.configurationJSON.utf8)) as? [String: Any] else { return false }
        switch connection {
        case .http(let address):
            guard let actual = object["url"] as? String else { return false }
            return Self.endpoint(actual) == Self.endpoint(address)
        case .stdio(let command, let arguments):
            return object["command"] as? String == command && object["args"] as? [String] == arguments
        }
    }

    func draft(name: String? = nil) -> MCPServerDraft {
        var draft = MCPServerDraft()
        draft.name = name ?? id
        switch connection {
        case .http(let address):
            draft.transport = .http
            draft.url = address
        case .stdio(let command, let arguments):
            draft.commandLine = ([command] + arguments).map(MCPCommandLine.quote).joined(separator: " ")
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
        parts.query = nil
        parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string
    }

    static let all: [MCPMarketPreset] = [
        remote("context7", "Context7", "Upstash", "books.vertical", "https://mcp.context7.com/mcp", docs: "https://context7.com/docs/installation"),
        MCPMarketPreset(id: "playwright", name: "Playwright", publisher: "Microsoft", symbol: "globe", connection: .stdio(command: "npx", arguments: ["-y", "@playwright/mcp@latest"]), documentationURL: "https://github.com/microsoft/playwright-mcp"),
        remote("deepwiki", "DeepWiki", "Cognition", "text.book.closed", "https://mcp.deepwiki.com/mcp", docs: "https://mcp.deepwiki.com/"),
        remote("exa", "Exa", "Exa", "magnifyingglass", "https://mcp.exa.ai/mcp", docs: "https://exa.ai/docs/reference/exa-mcp"),
        remote("sentry", "Sentry", "Sentry", "exclamationmark.triangle", "https://mcp.sentry.dev/mcp", login: true, docs: "https://github.com/sentry-official/sentry-mcp"),
        remote("linear", "Linear", "Linear", "checklist", "https://mcp.linear.app/mcp", login: true, docs: "https://linear.app/docs/mcp"),
        remote("notion", "Notion", "Notion", "doc.text", "https://mcp.notion.com/mcp", login: true, docs: "https://www.notion.com/help/notion-mcp"),
        remote("supabase", "Supabase", "Supabase", "externaldrive", "https://mcp.supabase.com/mcp", login: true, docs: "https://supabase.com/docs/guides/ai-tools/mcp"),
        remote("stripe", "Stripe", "Stripe", "creditcard", "https://mcp.stripe.com", login: true, docs: "https://docs.stripe.com/mcp"),
        remote("vercel", "Vercel", "Vercel", "arrow.up.forward.square", "https://mcp.vercel.com", login: true, docs: "https://vercel.com/docs/agent-resources/vercel-mcp"),
        remote("cloudflare-docs", "Cloudflare Docs", "Cloudflare", "cloud", "https://docs.mcp.cloudflare.com/mcp", docs: "https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/"),
        remote("microsoft-learn", "Microsoft Learn", "Microsoft", "book", "https://learn.microsoft.com/api/mcp", docs: "https://learn.microsoft.com/training/support/mcp"),
        remote("hugging-face", "Hugging Face", "Hugging Face", "square.stack.3d.up", "https://hf.co/mcp", docs: "https://huggingface.co/docs/hub/en/agents-mcp")
    ]

    private static func remote(_ id: String, _ name: String, _ publisher: String, _ symbol: String, _ url: String, login: Bool = false, docs: String) -> MCPMarketPreset {
        MCPMarketPreset(id: id, name: name, publisher: publisher, symbol: symbol, connection: .http(url), requiresLogin: login, documentationURL: docs)
    }

}
