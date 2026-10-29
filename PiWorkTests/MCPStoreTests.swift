import XCTest
import SwiftUI
@testable import PiWork

@MainActor
final class MCPStoreTests: XCTestCase {
    func testLoadsServersAndRecoversFromARequestFailure() async {
        let service = MCPTestService()
        let store = MCPStore(service: service)
        await service.setFailure(true)
        await store.load()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
        await service.setFailure(false)
        await store.load()
        XCTAssertEqual(store.servers.map(\.name), ["fixture"])
        XCTAssertNil(store.errorMessage)
    }

    func testDoesNotProbeAgentsWithoutTheMCPCapability() async {
        let service = MCPTestService(supported: false)
        let store = MCPStore(service: service)
        await store.load()
        XCTAssertFalse(store.isSupported)
        let requests = await service.snapshotRequests
        XCTAssertEqual(requests, 0)
    }

    func testSaveAndDisableUseTheTypedManagementContract() async {
        let service = MCPTestService()
        let store = MCPStore(service: service)
        await store.load()
        let saved = await store.save(MCPSaveParameters(name: "fixture", configurationJSON: "{\"url\":\"https://example.com/mcp\"}", allowInChat: true, readOnlyTools: ["mcp__fixture__read"]))
        XCTAssertTrue(saved)
        let parameters = await service.lastSave
        XCTAssertEqual(parameters?.readOnlyTools, ["mcp__fixture__read"])
        XCTAssertEqual(parameters?.allowInChat, true)
        await store.action("disable", server: store.servers[0])
        let action = await service.lastAction
        XCTAssertEqual(action?.name, "fixture")
        XCTAssertEqual(action?.action, "disable")
        XCTAssertFalse(store.isWorking)
    }

    func testOAuthURLIsOpenedOnlyOnceAndRejectsOtherSchemes() async {
        let service = MCPTestService()
        let store = MCPStore(service: service)
        await service.setAuthURL("https://example.com/authorize?state=fixture")
        await store.load()
        XCTAssertNotNil(store.takeAuthorizationURL())
        XCTAssertNil(store.takeAuthorizationURL())
        await service.setAuthURL("javascript:alert(1)")
        await store.load()
        XCTAssertNil(store.takeAuthorizationURL())
        XCTAssertNil(MCPStore.webURL("file:///tmp/test"))
        XCTAssertNil(MCPStore.webURL("https://user:password@example.com"))
    }

    func testManagementRequestsAreNamespacedAndCapabilityGated() throws {
        let request = AgentHostRequest(id: "mcp-1", method: "mcp.action", params: MCPActionParameters(name: "fixture", action: "login"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encodedLine()) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "_piWork/mcp/action")
        XCTAssertEqual(AgentHostPiWorkCapability(rawValue: "mcp.action"), .mcpAction)
    }

    func testNativeSettingsFitsNarrowAndWideDetailPanels() async {
        let store = MCPStore(service: MCPTestService())
        await store.load()
        let controller = NSHostingController(rootView: MCPSettingsView(store: store))
        for width: CGFloat in [436, 620, 900] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 620))
            XCTAssertLessThanOrEqual(size.width, width)
        }
    }
}

private actor MCPTestService: MCPServicing {
    let supported: Bool
    var shouldFail = false
    var snapshotRequests = 0
    var lastSave: MCPSaveParameters?
    var lastAction: MCPActionParameters?
    var authURL: String?

    init(supported: Bool = true) { self.supported = supported }
    func setFailure(_ value: Bool) { shouldFail = value }
    func setAuthURL(_ value: String) { authURL = value }
    func start() async throws -> AgentHostHelloPayload {
        AgentHostHelloPayload(hostVersion: "test", piVersion: "1.4.0", capabilities: [],
                              piWorkCapabilities: supported ? [.mcpList, .mcpAction, .mcpSave, .mcpImport] : [], supportsPiWorkExtensions: supported)
    }
    func mcpSnapshot() async throws -> MCPSnapshot {
        snapshotRequests += 1
        if shouldFail { throw URLError(.cannotConnectToHost) }
        return snapshot()
    }
    func saveMCP(_ parameters: MCPSaveParameters) async throws -> MCPSnapshot { lastSave = parameters; return snapshot() }
    func importMCP(_ configurationJSON: String) async throws -> MCPSnapshot { snapshot() }
    func performMCPAction(_ parameters: MCPActionParameters) async throws -> MCPSnapshot { lastAction = parameters; return snapshot() }
    private func snapshot() -> MCPSnapshot {
        MCPSnapshot(servers: [MCPServer(name: "fixture", transport: "http", enabled: true,
            configurationJSON: "{\"url\":\"https://example.com/mcp\"}", allowInChat: false,
            readOnlyTools: [], status: "connected", tools: [MCPTool(name: "read", callName: "mcp__fixture__read", description: "Read a record", readOnly: true)],
            error: nil, canLogin: true, signedIn: false)], errors: [],
            auth: authURL.map { MCPAuthentication(name: "fixture", state: "authorizing", url: $0, error: nil) })
    }
}
