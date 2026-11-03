import XCTest
@testable import PiWork

final class MCPMarketTests: XCTestCase {
    func testCatalogContainsExactlyTheRequestedPresets() {
        XCTAssertEqual(MCPMarketPreset.all.map(\.id), [
            "context7", "playwright", "deepwiki", "exa", "sentry", "linear", "notion",
            "supabase", "stripe", "vercel", "cloudflare-docs", "microsoft-learn", "hugging-face"
        ])
        XCTAssertEqual(Set(MCPMarketPreset.all.map(\.id)).count, 13)
    }

    func testEveryRecipeProducesAValidDeferredConfigurationWithoutCredentials() throws {
        for preset in MCPMarketPreset.all {
            let draft = preset.draft()
            XCTAssertNil(draft.validationError, preset.id)
            let json = try draft.configurationJSON()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(object["exposure"] as? String, "deferred", preset.id)
            XCTAssertTrue((object["headers"] as? [String: String] ?? [:]).isEmpty)
            XCTAssertTrue((object["env"] as? [String: String] ?? [:]).isEmpty)
            XCTAssertNotNil(MCPStore.webURL(preset.documentationURL))
            var copy = MCPServerDraft()
            copy.name = draft.name
            try copy.applyJSON(json)
            XCTAssertNil(copy.validationError)
        }
    }

    func testEndpointMatchingFindsRenamedAndProjectScopedServers() throws {
        let supabase = try XCTUnwrap(MCPMarketPreset.all.first { $0.id == "supabase" })
        XCTAssertTrue(supabase.matches(server("renamed", #"{"url":"https://MCP.SUPABASE.COM/mcp/?project_ref=example&read_only=true"}"#)))
        XCTAssertFalse(supabase.matches(server("supabase", #"{"url":"https://example.com/mcp"}"#)))
    }

    func testLocalRecipeRequiresCommandAndArgumentsToMatch() throws {
        let playwright = try XCTUnwrap(MCPMarketPreset.all.first { $0.id == "playwright" })
        XCTAssertTrue(playwright.isLocal)
        XCTAssertTrue(playwright.matches(server("browser", try playwright.draft().configurationJSON())))
        XCTAssertFalse(playwright.matches(server("playwright", #"{"command":"npx","args":["-y","different-package"]}"#)))
    }

    func testSearchUsesNamesPublishersAndDescriptions() throws {
        let playwright = try XCTUnwrap(MCPMarketPreset.all.first { $0.id == "playwright" })
        XCTAssertTrue(playwright.matchesSearch(" PLAYWRIGHT "))
        XCTAssertTrue(playwright.matchesSearch("microsoft"))
        XCTAssertTrue(playwright.matchesSearch("  "))
        XCTAssertFalse(playwright.matchesSearch("no-such-tool"))
    }

    private func server(_ name: String, _ json: String) -> MCPServer {
        MCPServer(name: name, transport: "http", enabled: false, configurationJSON: json,
                  allowInChat: false, readOnlyTools: [], status: "unchecked", tools: [],
                  error: nil, canLogin: false, signedIn: false)
    }
}
