import XCTest
@testable import PiWork

final class MCPMarketTests: XCTestCase {
    private func page() throws -> MCPMarketPage {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mcp-registry.json")
        return try JSONDecoder().decode(MCPRegistryResponse.self, from: Data(contentsOf: fixture)).page()
    }

    func testDecodesNetworkCatalogAndKeepsRegistryIdentityAndPagination() throws {
        let page = try page()
        XCTAssertEqual(page.items.count, 6)
        XCTAssertEqual(page.nextCursor, "cursor/+ with space")
        XCTAssertEqual(page.items[0].id, "io.github.upstash/context7")
        XCTAssertEqual(page.items[0].name, "Context7")
        XCTAssertEqual(page.items[0].iconURLs.first?.absoluteString, "https://example.com/context7.svg")
        XCTAssertEqual(page.items[0].suggestedName, "context7")
    }

    func testSupportedRecipesAreDeferredAndUnsupportedTransportsCannotBeInstalled() throws {
        for preset in try page().items where preset.isInstallable {
            let draft = preset.draft()
            XCTAssertNil(draft.validationError)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try draft.configurationJSON().utf8)) as? [String: Any])
            XCTAssertEqual(object["exposure"] as? String, "deferred")
        }
        let legacy = try XCTUnwrap(page().items.first { $0.name == "Legacy service" })
        XCTAssertFalse(legacy.isInstallable)
        XCTAssertFalse(legacy.canQuickAdd)
    }

    func testPackageVersionsAndRequiredInputsSurviveWithoutCatalogSecrets() throws {
        let items = try page().items
        let playwright = try XCTUnwrap(items.first { $0.name == "Playwright" })
        XCTAssertEqual(try MCPCommandLine.parse(playwright.draft().commandLine), ["npx", "-y", "@playwright/mcp@0.0.1"])
        let filesystem = try XCTUnwrap(items.first { $0.name == "Filesystem" })
        XCTAssertEqual(try MCPCommandLine.parse(filesystem.draft().commandLine), ["uvx", "--with", "example-helper==1", "example-filesystem-mcp==1.0.0", "<allowed-directory>"])
        XCTAssertEqual(filesystem.environment["API_KEY"], "")
        XCTAssertFalse(filesystem.setupNotes.isEmpty)
        let cloud = try XCTUnwrap(items.first { $0.name == "Cloud workspace" })
        XCTAssertFalse(cloud.canQuickAdd)
        XCTAssertEqual(cloud.headers["Authorization"], "")
        XCTAssertTrue(cloud.iconURLs.isEmpty)
    }

    func testEndpointIdentityPreservesProjectAndTenantParameters() throws {
        let context7 = try XCTUnwrap(page().items.first)
        XCTAssertTrue(context7.matches(server("renamed", #"{"url":"https://MCP.CONTEXT7.COM/mcp/"}"#)))
        XCTAssertFalse(context7.matches(server("context7", #"{"url":"https://mcp.context7.com/mcp?project_ref=other"}"#)))
        XCTAssertFalse(context7.matches(server("context7", #"{"url":"https://example.com/mcp"}"#)))
    }

    func testRemoteSearchAndCursorAreEncodedWithoutChangingEndpoint() throws {
        let url = MCPRegistryClient.requestURL(search: "git hub&version=old", cursor: "cursor/+ with space")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "registry.modelcontextprotocol.io")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["version"], "latest")
        XCTAssertEqual(query["search"], "git hub&version=old")
        XCTAssertEqual(query["cursor"], "cursor/+ with space")
        XCTAssertNil(URLComponents(url: MCPRegistryClient.requestURL(search: "ab", cursor: nil), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "search" })
    }

    func testArtworkRejectsLocalOrCredentialBearingURLs() {
        for url in ["file:///tmp/icon", "http://example.com/icon", "https://localhost/icon", "https://127.0.0.1/icon", "https://10.0.0.1/icon", "https://192.168.1.1/icon", "https://user:secret@example.com/icon"] {
            XCTAssertNil(MCPMarketURL.publicHTTPS(url), url)
        }
        XCTAssertNotNil(MCPMarketURL.publicHTTPS("https://example.com/icon.svg"))
    }

    @MainActor
    func testPaginationDeduplicatesAndStopsRepeatedCursors() async throws {
        let first = try page()
        let client = RegistryFixtureClient(pages: [first, first])
        let store = MCPMarketCatalogStore(client: client)
        await store.load(search: "")
        await store.loadMore()
        XCTAssertEqual(store.items.count, first.items.count)
        XCTAssertNil(store.nextCursor)
        await store.loadMore()
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testBrowsingCacheAvoidsRepeatedRequestsAndForceRefreshReloads() async throws {
        let client = RegistryFixtureClient(pages: [try page(), try page()])
        let store = MCPMarketCatalogStore(client: client)
        await store.load(search: "")
        await store.load(search: "a")
        var calls = await client.calls
        XCTAssertEqual(calls, 1)
        await store.load(search: "", refresh: true)
        calls = await client.calls
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testFailedSearchDoesNotShowUnrelatedCachedResultsAndRetryRecovers() async throws {
        let client = RegistryFixtureClient(pages: [try page()])
        let store = MCPMarketCatalogStore(client: client)
        await store.load(search: "")
        await store.load(search: "missing")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.items.isEmpty)
        await store.load(search: "")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.items.count, 6)
    }

    private func server(_ name: String, _ json: String) -> MCPServer {
        MCPServer(name: name, transport: "http", enabled: false, configurationJSON: json,
                  allowInChat: false, readOnlyTools: [], status: "unchecked", tools: [],
                  error: nil, canLogin: false, signedIn: false)
    }
}

private actor RegistryFixtureClient: MCPRegistryLoading {
    var pages: [MCPMarketPage]
    var calls = 0
    init(pages: [MCPMarketPage]) { self.pages = pages }
    func page(search: String, cursor: String?) async throws -> MCPMarketPage {
        calls += 1
        guard !pages.isEmpty else { throw URLError(.notConnectedToInternet) }
        return pages.removeFirst()
    }
}
