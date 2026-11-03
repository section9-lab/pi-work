import AppKit
import Foundation
import SwiftUI

/// Network catalog contracts and layout checks using local JSON, never live servers.
@MainActor
enum MCPMarketChecks {
    static func page() throws -> MCPMarketPage {
        let repository = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: repository.appendingPathComponent("PiWorkTests/Fixtures/mcp-registry.json"))
        return try JSONDecoder().decode(MCPRegistryResponse.self, from: data).page()
    }

    static func run(store: MCPStore) async throws {
        let page = try page()
        let expect = MCPChecks.expect
        try expect(page.items.count == 6 && page.nextCursor == "cursor/+ with space", "Registry envelope or pagination changed")
        let context7 = page.items[0]
        try expect(context7.id == "io.github.upstash/context7" && context7.suggestedName == "context7", "Registry identity was confused with configuration name")
        try expect(context7.iconURLs.first?.absoluteString == "https://example.com/context7.svg", "Registry artwork was not preferred")
        for item in page.items where item.isInstallable {
            try expect(item.draft().validationError == nil, "Registry recipe cannot be edited: \(item.id)")
        }
        let local = page.items[3]
        try expect(local.environment["API_KEY"] == "" && !local.setupNotes.isEmpty, "Registry secrets or required inputs were trusted")
        try expect(try MCPCommandLine.parse(local.draft().commandLine) == ["uvx", "--with", "example-helper==1", "example-filesystem-mcp==1.0.0", "<allowed-directory>"], "Python package inputs or version were lost")
        try expect(!page.items[4].isInstallable && !page.items[4].canQuickAdd, "SSE-only recipe could execute")
        try expect(page.items[5].iconURLs.isEmpty && !page.items[5].canQuickAdd, "Unsafe icons or required headers bypassed review")
        for bad in ["file:///tmp/icon", "https://localhost/icon", "https://127.0.0.1/icon", "https://10.0.0.1/icon", "https://user:secret@example.com/icon"] {
            try expect(MCPMarketURL.publicHTTPS(bad) == nil, "Unsafe icon URL accepted")
        }
        let url = MCPRegistryClient.requestURL(search: "git hub&version=old", cursor: page.nextCursor)
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try expect(params.first { $0.name == "version" }?.value == "latest", "Search query changed registry version")
        try expect(params.first { $0.name == "cursor" }?.value == page.nextCursor, "Pagination cursor was not preserved")

        try await checkNetworkCache()
        let artwork = FixtureArtwork()
        let imageStore = MCPBrandImageStore(downloader: artwork)
        let iconURL = URL(string: "https://example.com/logo.svg")!
        let image = await imageStore.image(for: iconURL)
        try expect(image?.isValid == true && image?.size == NSSize(width: 96, height: 96), "Native SVG artwork did not rasterize")
        _ = await imageStore.image(for: iconURL)
        let downloads = await artwork.calls
        try expect(downloads == 1, "Brand artwork refetched despite a memory-cache hit")

        let client = FixtureRegistry(pages: [page, page])
        let catalog = MCPMarketCatalogStore(client: client)
        await catalog.load(search: "")
        await catalog.load(search: "a")
        var calls = await client.calls
        try expect(calls == 1, "Opening a cached directory refetched the network")
        await catalog.loadMore()
        try expect(catalog.items.count == page.items.count && catalog.nextCursor == nil, "Repeated pagination duplicates or loops")
        await catalog.load(search: "missing")
        try expect(catalog.errorMessage != nil && catalog.items.isEmpty, "Failed search displayed unrelated cached results")
        await catalog.load(search: "")
        try expect(catalog.items.count == page.items.count && catalog.errorMessage == nil, "Cached directory could not recover")
        calls = await client.calls
        try expect(calls == 3, "Registry request count changed unexpectedly")

        for language in AppLanguage.allCases {
            for key in ["mcp.market.load_failed", "mcp.market.loading", "mcp.market.load_more", "mcp.market.cached", "mcp.market.setup_required", "mcp.market.loaded_count"] {
                try expect(L10n.string(key, language: language) != key, "Missing registry translation: \(key)")
            }
        }
        // Deterministic layout: do not download publisher artwork in fixture checks.
        var layoutPage = page
        layoutPage.items = page.items.map { item in var copy = item; copy.iconURLs = []; return copy }
        layoutPage.nextCursor = nil
        let layoutCatalog = MCPMarketCatalogStore(client: FixtureRegistry(pages: [layoutPage]))
        await layoutCatalog.load(search: "")
        for scheme in [ColorScheme.light, .dark] {
            let controller = NSHostingController(rootView: MCPMarketView(store: store, catalog: layoutCatalog, onConfigure: { _ in })
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme))
            for width: CGFloat in [436, 620, 900] {
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 1800))
                try expect(size.width <= width + 1, "Registry market overflows at \(width)")
            }
            if let prefix = ProcessInfo.processInfo.environment["PI_WORK_MCP_MARKET_SCREENSHOT_PATH"] {
                let view = controller.view
                view.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let suffix = scheme == .dark ? "dark" : "light"
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-" + suffix + ".png"))
                }
            }
        }
        print("MCP registry checks passed: remote schema, icons, safe recipes, pagination, caching, failures and adaptive light/dark layouts.")
    }

    private static func checkNetworkCache() async throws {
        let repository = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: repository.appendingPathComponent("PiWorkTests/Fixtures/mcp-registry.json"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureRegistryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = MCPRegistryClient(session: session, cacheURL: root.appendingPathComponent("registry.json"))
        FixtureRegistryURLProtocol.setData(data)
        let online = try await client.page(search: "", cursor: nil)
        try MCPChecks.expect(online.items.count == 6 && !online.isCached, "Production HTTP client did not decode a registry response")
        FixtureRegistryURLProtocol.setData(nil)
        let offline = try await client.page(search: "", cursor: nil)
        try MCPChecks.expect(offline.isCached && offline.items.count == 6 && offline.nextCursor == nil,
                            "Production HTTP client did not restore the offline page safely")
        do {
            _ = try await client.page(search: "missing", cursor: nil)
            throw MCPChecks.Failure(message: "Failed search used the unfiltered disk cache")
        } catch is URLError { }
        do {
            _ = try await client.page(search: "", cursor: "next")
            throw MCPChecks.Failure(message: "Failed pagination used the first-page disk cache")
        } catch is URLError { }
    }
}

private actor FixtureArtwork: MCPArtworkLoading {
    private(set) var calls = 0
    func data(for url: URL) async -> Data? {
        calls += 1
        return Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" rx="8" fill="#23ab78"/></svg>"##.utf8)
    }
}

private final class FixtureRegistryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseData: Data?
    static func setData(_ data: Data?) { lock.lock(); responseData = data; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let data = Self.responseData; Self.lock.unlock()
        guard let data, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor FixtureRegistry: MCPRegistryLoading {
    private var pages: [MCPMarketPage]
    private(set) var calls = 0
    init(pages: [MCPMarketPage]) { self.pages = pages }
    func page(search: String, cursor: String?) async throws -> MCPMarketPage {
        calls += 1
        guard !pages.isEmpty else { throw URLError(.notConnectedToInternet) }
        return pages.removeFirst()
    }
}
