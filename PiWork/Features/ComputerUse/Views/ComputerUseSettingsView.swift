import AppKit
import SwiftUI

struct ComputerUseSettingsView: View {
    @ObservedObject var store: ComputerUseStore
    @State private var presentsRestartChoice = false
    @State private var presentsRelaunch = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.enabled }, set: { value in
                    Task { await store.setEnabled(value) }
                })) {
                    Text(L10n.string("computer_use.enable"))
                    Text(L10n.string("computer_use.description")).font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .disabled(!store.systemSupported || !store.runtimeSupported || store.isWorking || store.isLoading)
                .accessibilityIdentifier("computer-use-toggle")
                if !store.systemSupported || !store.runtimeSupported {
                    Text(L10n.string(store.statusKey)).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.string("computer_use.access_note"))
            }

            if store.systemSupported && store.runtimeSupported {
                Section(L10n.string("computer_use.permissions")) {
                    permissionRow("computer_use.accessibility", granted: store.snapshot?.permissions.accessibility == true,
                                  action: "accessibility")
                    permissionRow("computer_use.screen_recording", granted: store.snapshot?.permissions.screenRecording == true,
                                  action: "screenRecording")
                    Text(L10n.string("computer_use.helper_note")).font(.caption).foregroundStyle(.secondary)
                    if let path = store.snapshot?.helperPath {
                        Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Section {
                    LabeledContent(L10n.string("computer_use.status")) {
                        HStack {
                            if store.isWorking || store.isLoading { ProgressView().controlSize(.small) }
                            Text(L10n.string(store.statusKey)).accessibilityIdentifier("computer-use-status")
                        }
                    }
                    Button(L10n.string("computer_use.apply")) {
                        if store.isActive { presentsRestartChoice = true }
                        else { Task { await store.action("recheck") } }
                    }
                    .disabled(!store.enabled || store.isWorking || store.isTesting)
                    if store.isActive {
                        Button(L10n.string("computer_use.stop"), role: .destructive) {
                            Task { await store.action("stop") }
                        }
                    }
                    if store.snapshot?.permissions.attribution == "caller" {
                        Text(L10n.string("computer_use.attribution_note")).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.string("computer_use.relaunch")) { presentsRelaunch = true }
                    }
                } header: {
                    Text(L10n.string("computer_use.service"))
                } footer: {
                    Text(L10n.string("computer_use.restart_note"))
                }
                Section {
                    Button(L10n.string("computer_use.test")) {
                        ComputerUseTestWindow.shared.show()
                        Task { await store.test() }
                    }
                    .disabled(!store.isReady || store.isWorking || store.isActive || store.isTesting)
                    .accessibilityIdentifier("computer-use-test")
                    if store.isTesting { ProgressView(L10n.string("computer_use.testing")) }
                    if let result = store.verification {
                        verificationRow("computer_use.test_observe", success: result.observed)
                        verificationRow("computer_use.test_act", success: result.acted)
                        verificationRow("computer_use.test_verify", success: result.verified)
                    }
                } footer: {
                    Text(L10n.string("computer_use.test_note"))
                }
            }
            if let error = store.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button(L10n.string("common.retry")) { Task { await store.load(check: true) } }
                        .disabled(store.isWorking)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await store.load(check: true)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                await store.load(silent: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.load(check: true, silent: true) }
        }
        .confirmationDialog(L10n.string("computer_use.restart_busy"), isPresented: $presentsRestartChoice) {
            Button(L10n.string("computer_use.apply_when_idle")) { Task { await store.action("recheck") } }
            Button(L10n.string("computer_use.stop_apply"), role: .destructive) {
                Task { await store.action("recheck", force: true) }
            }
        }
        .alert(L10n.string("computer_use.relaunch"), isPresented: $presentsRelaunch) {
            Button(L10n.string("common.cancel"), role: .cancel) {}
            Button(L10n.string("computer_use.relaunch")) { ComputerUseTestWindow.relaunchApplication() }
        } message: { Text(L10n.string("computer_use.relaunch_note")) }
    }

    private func permissionRow(_ title: String, granted: Bool, action: String) -> some View {
        LabeledContent(L10n.string(title)) {
            HStack {
                Text(L10n.string(granted ? "computer_use.granted" : "computer_use.not_granted"))
                    .foregroundStyle(.secondary)
                Button(L10n.string("computer_use.open_settings")) { Task { await store.action(action) } }
                    .disabled(!store.enabled || store.isWorking || store.isActive || store.isTesting)
            }
        }
    }
    private func verificationRow(_ title: String, success: Bool) -> some View {
        LabeledContent(L10n.string(title)) {
            Text(L10n.string(success ? "computer_use.passed" : "computer_use.not_passed"))
        }
    }
}

@MainActor
final class ComputerUseTestWindow {
    static let shared = ComputerUseTestWindow()
    private var window: NSWindow?
    func show() {
        window?.close()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        let label = NSTextField(labelWithString: L10n.string("computer_use.test_window_note"))
        label.frame = NSRect(x: 24, y: 102, width: 372, height: 36)
        label.lineBreakMode = .byWordWrapping
        let field = NSTextField(frame: NSRect(x: 24, y: 56, width: 372, height: 28))
        field.setAccessibilityIdentifier("piwork-computer-use-test-input")
        field.setAccessibilityLabel("PiWork computer use test input")
        content.addSubview(label)
        content.addSubview(field)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PiWork Computer Use Test"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
    static func relaunchApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, error in
            guard error == nil, let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
}

struct ComputerUseShortcut: View {
    @ObservedObject var store: ComputerUseStore
    var body: some View {
        Menu {
            Text(L10n.string(store.statusKey))
            if #available(macOS 14, *) {
                ComputerUseOpenSettingsButton()
            } else {
                Button(L10n.string("computer_use.settings")) { showSettings() }
            }
            if store.isActive {
                Button(L10n.string("computer_use.stop"), role: .destructive) { Task { await store.action("stop") } }
            }
        } label: {
            MCPGlyph(name: "Monitor")
                .frame(width: MCPMetrics.controlHeight, height: MCPMetrics.controlHeight)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L10n.string("computer_use.title") + ": " + L10n.string(store.statusKey))
        .accessibilityLabel(L10n.string("computer_use.title") + ": " + L10n.string(store.statusKey))
        .accessibilityIdentifier("computer-use-shortcut")
        .task {
            await store.load()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                await store.load(silent: true)
            }
        }
    }
    @MainActor private func showSettings() {
        AppSettingsNavigation.shared.selection = .computerUse
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@available(macOS 14, *)
private struct ComputerUseOpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button(L10n.string("computer_use.settings")) {
            AppSettingsNavigation.shared.selection = .computerUse
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
