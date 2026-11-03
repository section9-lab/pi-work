import Combine
import Foundation

@MainActor
final class MCPMarketCatalogStore: ObservableObject {
    @Published private(set) var items: [MCPMarketPreset] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isCached = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var nextCursor: String?
    @Published private(set) var knownItems: [String: MCPMarketPreset] = [:]
    private let client: any MCPRegistryLoading
    private var query = ""
    private var requestID = UUID()
    private var failedContinuation = false
    private var consumedCursors = Set<String>()
    private var identityAttempts: [String: Date] = [:]
    private var browseCache: (items: [MCPMarketPreset], cursor: String?, date: Date)?

    init(client: any MCPRegistryLoading = MCPRegistryClient()) { self.client = client }

    func load(search: String, refresh: Bool = false) async {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmed.count >= 3 ? trimmed : ""
        let queryChanged = self.query != query
        let id = UUID()
        requestID = id
        failedContinuation = false
        self.query = query
        errorMessage = nil
        consumedCursors = []
        if !refresh, query.isEmpty, let cache = browseCache, Date().timeIntervalSince(cache.date) < 3600 {
            items = cache.items
            nextCursor = cache.cursor
            isLoading = false
            isCached = false
            return
        }
        isLoading = true
        if !refresh || queryChanged { items = []; nextCursor = nil }
        isCached = false
        defer { if requestID == id { isLoading = false } }
        do {
            let page = try await client.page(search: query, cursor: nil)
            guard requestID == id, !Task.isCancelled else { return }
            items = page.items
            nextCursor = page.nextCursor
            isCached = page.isCached
            remember(page.items)
            if query.isEmpty, !page.isCached { browseCache = (items, nextCursor, Date()) }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !isLoading, let cursor = nextCursor, !consumedCursors.contains(cursor) else { return }
        let id = requestID
        isLoading = true
        errorMessage = nil
        failedContinuation = true
        defer { if requestID == id { isLoading = false } }
        do {
            let page = try await client.page(search: query, cursor: cursor)
            guard requestID == id, !Task.isCancelled else { return }
            consumedCursors.insert(cursor)
            let existing = Set(items.map(\.id))
            items += page.items.filter { !existing.contains($0.id) }
            nextCursor = page.nextCursor.flatMap { consumedCursors.contains($0) ? nil : $0 }
            isCached = page.isCached
            remember(page.items)
            if query.isEmpty, !page.isCached { browseCache = (items, nextCursor, Date()) }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func retry() async {
        if failedContinuation { await loadMore() }
        else { await load(search: query, refresh: true) }
    }

    func preset(for server: MCPServer) -> MCPMarketPreset? {
        if let exact = knownItems.values.first(where: { $0.matches(server) }) { return exact }
        // Artwork can be shared across project-scoped endpoints; installed-state
        // detection still uses the full connection identity in MCPStore.
        guard let object = try? JSONSerialization.jsonObject(with: Data(server.configurationJSON.utf8)) as? [String: Any],
              let address = object["url"] as? String, let host = URL(string: address)?.host else { return nil }
        return knownItems.values.first {
            if case .http(let candidate) = $0.connection { return URL(string: candidate)?.host == host }
            return false
        }
    }

    func resolveIdentities(for servers: [MCPServer]) async {
        for server in servers.prefix(24) {
            guard !Task.isCancelled else { return }
            guard preset(for: server) == nil else { continue }
            var query = server.name
            if let object = try? JSONSerialization.jsonObject(with: Data(server.configurationJSON.utf8)) as? [String: Any],
               let address = object["url"] as? String, let host = URL(string: address)?.host {
                query = host.split(separator: ".").first(where: { !["www", "mcp", "api"].contains(String($0)) }).map(String.init) ?? query
            }
            guard query.count >= 3, identityAttempts[query].map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { continue }
            identityAttempts[query] = Date()
            if let page = try? await client.page(search: query, cursor: nil), !Task.isCancelled {
                remember(page.items)
            }
        }
    }

    private func remember(_ items: [MCPMarketPreset]) {
        // A bounded metadata cache, not a second downloaded copy of the registry.
        if knownItems.count + items.count > 1024 { knownItems = [:] }
        for item in items { knownItems[item.id] = item }
    }
}
