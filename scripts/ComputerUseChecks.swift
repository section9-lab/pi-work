import AppKit
import Foundation
import SwiftUI

/// Native lifecycle/layout and real compiled-host checks without XCTest.
@MainActor
enum ComputerUseChecks {
    static func run(service: AgentHostService, repository: URL) async throws {
        func expect(_ value: Bool, _ message: String) throws {
            try MCPChecks.expect(value, "Computer use: " + message)
        }
        let snapshot = try await service.computerUseSnapshot()
        try expect(!snapshot.enabled && snapshot.activeCalls == 0, "must be off on a fresh installation")
        try expect(snapshot.status == "disabled" || snapshot.status == "unsupported", "snapshot started a helper")
        let legacy = ComputerUseStore(service: service, systemSupported: false)
        await legacy.load(check: true)
        await legacy.setEnabled(true)
        try expect(!legacy.enabled && legacy.statusKey == "computer_use.unsupported", "macOS 13 gate failed")
        let store = ComputerUseStore(service: service, systemSupported: true)
        await store.load()
        try expect(store.runtimeSupported && !store.enabled, "native RPC capability gate failed")
        let request = AgentHostRequest(id: "cu-check", method: "computerUse.action",
                                       params: ComputerUseActionParameters(action: "stop"))
        let encoded = try JSONSerialization.jsonObject(with: request.encodedLine()) as? [String: Any]
        try expect(encoded?["method"] as? String == "_piWork/computerUse/action", "RPC is not namespaced")
        let controller = NSHostingController(rootView: ComputerUseSettingsView(store: store))
        for width: CGFloat in [436, 620, 900] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 620))
            try expect(size.width <= width, "settings overflow at \(width)")
        }
        let monitor = Bundle.main.url(forResource: "LucideMonitor", withExtension: "pdf").flatMap { NSImage(contentsOf: $0) }
        try expect(monitor?.isValid == true, "Lucide monitor asset is missing")
        let language = LanguageStore.shared.language
        LanguageStore.shared.language = .simplifiedChinese
        defer { LanguageStore.shared.language = language }
        for appearance in [ColorScheme.light, .dark] {
            let preview = NSHostingController(rootView: ComputerUseSettingsView(store: store).environment(\.colorScheme, appearance))
            let view = preview.view
            view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let suffix = appearance == .dark ? "dark" : "light"
                try bitmap.representation(using: .png, properties: [:])?.write(to: repository.appendingPathComponent("build/computer-use-settings-\(suffix).png"))
            }
        }
    }
}
