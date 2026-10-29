import AppKit
import Foundation
import SwiftUI

/// Standalone local QA shell for the production settings page and real Host.
/// No model credentials, login, user conversations, or external apps are used.
@main
@MainActor
struct ComputerUsePreview: App {
    @StateObject private var store: ComputerUseStore

    init() {
        let agent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pi-work-computer-use-qa/Agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let service = AgentHostService(
            executableURL: AgentHostExecutable.bundledURL()!,
            environment: [
                "PI_WORK_AGENT_DIR": agent.path, "PI_CODING_AGENT_DIR": agent.path,
                "PI_WORK_AUTH_PATH": agent.appendingPathComponent("auth.json").path,
                "PI_WORK_APP_PID": String(ProcessInfo.processInfo.processIdentifier),
                "PI_WORK_SKIP_REQUIRED_EXTENSION_INSTALL": "1",
                "PI_WORK_COMPUTER_USE_BUNDLE_PATH": Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Resources/ComputerUse/pi-computer-use.app").path
            ], handshakeTimeout: 15)
        _store = StateObject(wrappedValue: ComputerUseStore(service: service))
    }

    var body: some Scene {
        WindowGroup("PiWork · Computer Use") {
            ComputerUseSettingsView(store: store)
        }
        .defaultSize(width: 620, height: 760)
    }
}
