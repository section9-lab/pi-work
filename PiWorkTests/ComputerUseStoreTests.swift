import XCTest
import SwiftUI
@testable import PiWork

@MainActor
final class ComputerUseStoreTests: XCTestCase {
    func testMacOS13NeverCallsTheHostOrEnablesTheFeature() async {
        let service = ComputerUseTestService()
        let store = ComputerUseStore(service: service, systemSupported: false)
        await store.load(check: true)
        await store.setEnabled(true)
        XCTAssertEqual(store.statusKey, "computer_use.unsupported")
        XCTAssertFalse(store.enabled)
        let calls = await service.requests
        XCTAssertEqual(calls, 0)
    }

    func testMissingRuntimeCapabilityDoesNotSendUnsupportedRequests() async {
        let service = ComputerUseTestService(supported: false)
        let store = ComputerUseStore(service: service, systemSupported: true)
        await store.load()
        XCTAssertFalse(store.runtimeSupported)
        XCTAssertEqual(store.statusKey, "computer_use.runtime_unsupported")
        let calls = await service.requests
        XCTAssertEqual(calls, 0)
    }

    func testPermissionSetupKeepsEnableIntentAndRecheckTransitionsToReady() async {
        let service = ComputerUseTestService()
        let store = ComputerUseStore(service: service, systemSupported: true)
        await store.load()
        await store.setEnabled(true)
        XCTAssertTrue(store.enabled)
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(store.statusKey, "computer_use.setup_required")
        await store.action("recheck")
        XCTAssertTrue(store.isReady)
        await store.test()
        XCTAssertTrue(store.verification?.verified == true)
        await store.setEnabled(false)
        XCTAssertFalse(store.isReady)
        XCTAssertNil(store.verification)
    }

    func testFailedCallsKeepThePreviousStateAndCanBeRetried() async {
        let service = ComputerUseTestService()
        let store = ComputerUseStore(service: service, systemSupported: true)
        await store.load()
        await service.setFailure(true)
        await store.setEnabled(true)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isWorking)
        await service.setFailure(false)
        await store.setEnabled(true)
        XCTAssertTrue(store.enabled)
        XCTAssertNil(store.errorMessage)
    }

    func testRPCNamesAndNativeLayout() throws {
        let request = AgentHostRequest(id: "computer-use", method: "computerUse.action",
                                       params: ComputerUseActionParameters(action: "recheck", force: true))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encodedLine()) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "_piWork/computerUse/action")
        let view = NSHostingController(rootView: ComputerUseSettingsView(
            store: ComputerUseStore(service: ComputerUseTestService(), systemSupported: false)))
        for width: CGFloat in [436, 620, 900] {
            XCTAssertLessThanOrEqual(view.sizeThatFits(in: CGSize(width: width, height: 620)).width, width)
        }
    }
}

private actor ComputerUseTestService: ComputerUseServicing {
    let supported: Bool
    var requests = 0
    var enabled = false
    var ready = false
    var failure = false
    init(supported: Bool = true) { self.supported = supported }
    func setFailure(_ value: Bool) { failure = value }
    func start() async throws -> AgentHostHelloPayload {
        AgentHostHelloPayload(hostVersion: "test", piVersion: "1.4.0", capabilities: [],
            piWorkCapabilities: supported ? [.computerUseGet, .computerUseAction, .computerUseVerify] : [],
            supportsPiWorkExtensions: supported)
    }
    func computerUseSnapshot(check: Bool) async throws -> ComputerUseSnapshot {
        requests += 1
        if failure { throw URLError(.cannotConnectToHost) }
        return snapshot()
    }
    func computerUseAction(_ action: String, force: Bool) async throws -> ComputerUseSnapshot {
        requests += 1
        if failure { throw URLError(.cannotConnectToHost) }
        if action == "enable" { enabled = true }
        if action == "disable" { enabled = false }
        if action == "recheck" { ready = true }
        return snapshot()
    }
    func verifyComputerUse() async throws -> ComputerUseVerification {
        ComputerUseVerification(observed: true, acted: true, verified: true, error: nil)
    }
    private func snapshot() -> ComputerUseSnapshot {
        ComputerUseSnapshot(supported: true, enabled: enabled,
            status: !enabled ? "disabled" : ready ? "ready" : "setupRequired",
            permissions: ComputerUsePermissions(accessibility: ready, screenRecording: ready,
                screenRecordingPreflight: ready, attribution: "helper-app"), helperPath: "/test/pi-computer-use.app",
            activeCalls: 0, pendingRestart: false, generation: 0, error: nil)
    }
}
