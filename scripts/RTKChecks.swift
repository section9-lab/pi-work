import AppKit
import Foundation
import SwiftUI

/// RTK service, presentation and layout checks for hosts with Command Line Tools only.
@MainActor
enum RTKChecks {
    struct Failure: Error { let message: String }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    static func run(service: AgentHostService, repository: URL) async throws {
        let store = RTKStore(service: service)
        await store.load()
        try expect(store.runtimeSupported && store.snapshot != nil && store.errorMessage == nil,
                   "RTK capability negotiation or native decoding failed: \(store.errorMessage ?? "missing state")")
        await store.action("disable")
        try expect(!store.enabled && store.errorMessage == nil, "RTK disable did not persist through ACP")
        if store.snapshot?.path != nil {
            await store.action("enable")
            try expect(store.enabled && store.errorMessage == nil, "RTK could not reuse an existing installation")
            await store.action("disable")
        }

        let unsupported = RTKStore(service: Fixture(supported: false))
        await unsupported.load()
        await unsupported.action("install")
        try expect(!unsupported.runtimeSupported && unsupported.snapshot == nil,
                   "Older runtimes received unsupported RTK requests")

        let fixture = Fixture()
        let preview = RTKStore(service: fixture)
        await preview.load()
        await fixture.setFailure(true)
        await preview.action("disable")
        try expect(preview.enabled && preview.errorMessage != nil && !preview.isBusy,
                   "Failed requests discarded the last confirmed RTK state")
        await fixture.setFailure(false)
        await preview.load()
        try expect(preview.errorMessage != nil, "Background refresh hid an actionable RTK failure")
        await preview.retry()
        try expect(!preview.enabled && preview.errorMessage == nil, "RTK retry did not recover")

        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        let statistics = RTKStatistics(snapshot: Fixture.snapshot, range: .month, now: date)
        try expect(statistics.days.count == 2 && statistics.gain.commands == 5 && statistics.gain.pct == 25,
                   "30-day boundaries or weighted savings are incorrect")
        try expect(Fixture.snapshot.updateAvailable, "Semantic version comparison failed for 1.9 → 1.10")

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = repository.appendingPathComponent("build/RTK-QA")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            app.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let controller = NSHostingController(rootView: RTKSettingsView(store: preview)
                .preferredColorScheme(scheme).environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en")))
            controller.view.appearance = app.appearance
            for width: CGFloat in [436, 620, 900] {
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 780))
                try expect(size.width <= width, "RTK settings overflowed a \(width)-point pane")
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 780)
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
                if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: output.appendingPathComponent("rtk-\(name)-\(Int(width)).png"))
                }
            }
        }
        print("RTK native checks passed: ACP, persistence, runtime compatibility, retry, statistics, light/dark layout at 436/620/900 points.")
    }

    private actor Fixture: RTKServicing {
        let supported: Bool
        var failure = false
        var enabled = true
        init(supported: Bool = true) { self.supported = supported }
        func setFailure(_ value: Bool) { failure = value }
        func start() async throws -> AgentHostHelloPayload {
            AgentHostHelloPayload(hostVersion: "test", piVersion: "1.4.0", capabilities: [],
                piWorkCapabilities: supported ? [.rtkGet, .rtkAction] : [], supportsPiWorkExtensions: supported)
        }
        func rtkSnapshot(checkLatest: Bool) async throws -> RTKSnapshot {
            if !supported || failure { throw URLError(.cannotConnectToHost) }
            let value = Self.snapshot
            return RTKSnapshot(supported: true, enabled: enabled, path: value.path, version: value.version,
                latestVersion: value.latestVersion, gain: value.gain, days: value.days, statsError: nil, updateError: nil)
        }
        func rtkAction(_ action: String) async throws -> RTKSnapshot {
            if !supported || failure { throw URLError(.cannotConnectToHost) }
            enabled = action != "disable"
            return try await rtkSnapshot(checkLatest: false)
        }
        static let snapshot = RTKSnapshot(supported: true, enabled: true, path: "/test/rtk", version: "1.9.0",
            latestVersion: "1.10.0", gain: RTKGain(commands: 6, input: 500, saved: 200, pct: 40), days: [
                RTKDay(date: "2026-09-29", commands: 1, input: 100, saved: 100, pct: 100),
                RTKDay(date: "2026-09-30", commands: 2, input: 100, saved: 100, pct: 100),
                RTKDay(date: "2026-10-29", commands: 3, input: 300, saved: 0, pct: 0)
            ], statsError: nil, updateError: nil)
    }
}
