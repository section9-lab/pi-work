import AppKit
import Foundation
import SwiftUI

/// Standalone local QA shell for the production settings page and real Host.
/// No model credentials, login, user conversations, or external apps are used.
@main
@MainActor
struct ComputerUsePreview {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let repository = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
            : Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let agent = repository.appendingPathComponent("build/ComputerUseQA/Agent")
        let service = AgentHostService(
            executableURL: repository.appendingPathComponent("build/pi-work-computer-use-host-\(architecture)"),
            environment: [
                "PI_WORK_AGENT_DIR": agent.path, "PI_CODING_AGENT_DIR": agent.path,
                "PI_WORK_AUTH_PATH": agent.appendingPathComponent("auth.json").path,
                "PI_WORK_APP_PID": String(ProcessInfo.processInfo.processIdentifier),
                "PI_WORK_SKIP_REQUIRED_EXTENSION_INSTALL": "1",
                "PI_WORK_COMPUTER_USE_BUNDLE_PATH": Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Resources/ComputerUse/pi-computer-use.app").path
            ])
        let store = ComputerUseStore(service: service)
        let view = ComputerUseSettingsView(store: store)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "PiWork · Computer Use"
        window.setContentSize(NSSize(width: 620, height: 760))
        window.styleMask.insert(.resizable)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
