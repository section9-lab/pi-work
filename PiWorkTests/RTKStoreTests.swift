import SwiftUI
import XCTest
@testable import PiWork

@MainActor
final class RTKStoreTests: XCTestCase {
    func testOlderRuntimeNeverReceivesUnsupportedRTKRequests() async {
        let service = RTKTestService(supported: false)
        let store = RTKStore(service: service)
        await store.load()
        await store.action("install")
        XCTAssertFalse(store.runtimeSupported)
        XCTAssertNil(store.snapshot)
        let requests = await service.requests
        XCTAssertEqual(requests, 0)
    }

    func testInstallEnableDisableAndRetryKeepTheLastConfirmedState() async {
        let service = RTKTestService()
        let store = RTKStore(service: service)
        await store.load()
        XCTAssertFalse(store.enabled)
        await store.action("install")
        XCTAssertTrue(store.enabled)
        await service.setFailure(true)
        await store.action("disable")
        XCTAssertTrue(store.enabled)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isBusy)
        await service.setFailure(false)
        await store.load()
        XCTAssertNotNil(store.errorMessage)
        await store.retry()
        XCTAssertFalse(store.enabled)
        XCTAssertNil(store.errorMessage)
    }

    func testPeriodsAreInclusiveAndPercentagesUseWeightedTokenTotals() throws {
        let snapshot = RTKTestService.statistics
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12)))
        let month = RTKStatistics(snapshot: snapshot, range: .month, now: now)
        XCTAssertEqual(month.days.map(\.date), ["2026-09-30", "2026-10-29"])
        XCTAssertEqual(month.gain.commands, 5)
        XCTAssertEqual(month.gain.pct, 25, accuracy: 0.001)
        let quarter = RTKStatistics(snapshot: snapshot, range: .quarter, now: now)
        XCTAssertEqual(quarter.days.count, 3)
        XCTAssertEqual(RTKStatistics(snapshot: snapshot, range: .all, now: now).gain, snapshot.gain)
    }

    func testWireNamesAndUpdateComparison() throws {
        let request = AgentHostRequest(id: "rtk", method: "rtk.action", params: RTKActionParameters(action: "install"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encodedLine()) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "_piWork/rtk/action")
        XCTAssertTrue(RTKTestService.statistics.updateAvailable)
    }

    func testSettingsFitNarrowAndWidePanes() async {
        let store = RTKStore(service: RTKTestService())
        await store.load()
        let controller = NSHostingController(rootView: RTKSettingsView(store: store))
        for width: CGFloat in [436, 620, 900] {
            XCTAssertLessThanOrEqual(controller.sizeThatFits(in: CGSize(width: width, height: 620)).width, width)
        }
    }
}

private actor RTKTestService: RTKServicing {
    let supported: Bool
    var requests = 0
    var enabled = false
    var failure = false
    init(supported: Bool = true) { self.supported = supported }
    func setFailure(_ value: Bool) { failure = value }
    func start() async throws -> AgentHostHelloPayload {
        AgentHostHelloPayload(hostVersion: "test", piVersion: "1.4.0", capabilities: [],
            piWorkCapabilities: supported ? [.rtkGet, .rtkAction] : [], supportsPiWorkExtensions: supported)
    }
    func rtkSnapshot(checkLatest: Bool) async throws -> RTKSnapshot {
        requests += 1
        if failure { throw URLError(.cannotConnectToHost) }
        let data = Self.statistics
        return RTKSnapshot(supported: true, enabled: enabled, path: data.path, version: data.version,
            latestVersion: data.latestVersion, gain: data.gain, days: data.days, statsError: nil, updateError: nil)
    }
    func rtkAction(_ action: String) async throws -> RTKSnapshot {
        if failure { throw URLError(.cannotConnectToHost) }
        enabled = action != "disable"
        return try await rtkSnapshot(checkLatest: false)
    }
    static let statistics = RTKSnapshot(supported: true, enabled: true, path: "/test/rtk", version: "1.9.0",
        latestVersion: "1.10.0", gain: RTKGain(commands: 6, input: 500, saved: 200, pct: 40), days: [
            RTKDay(date: "2026-09-29", commands: 1, input: 100, saved: 100, pct: 100),
            RTKDay(date: "2026-09-30", commands: 2, input: 100, saved: 100, pct: 100),
            RTKDay(date: "2026-10-29", commands: 3, input: 300, saved: 0, pct: 0)
        ], statsError: nil, updateError: nil)
}
