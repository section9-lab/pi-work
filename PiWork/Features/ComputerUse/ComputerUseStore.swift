import Combine
import Foundation

@MainActor
final class ComputerUseStore: ObservableObject {
    @Published private(set) var snapshot: ComputerUseSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var isTesting = false
    @Published private(set) var runtimeSupported = true
    @Published private(set) var verification: ComputerUseVerification?
    @Published var errorMessage: String?
    let systemSupported: Bool
    private let service: any ComputerUseServicing
    private var isRefreshing = false

    init(service: any ComputerUseServicing, systemSupported: Bool? = nil) {
        self.service = service
        self.systemSupported = systemSupported ?? ProcessInfo.processInfo
            .isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
    }

    var enabled: Bool { snapshot?.enabled == true }
    var isReady: Bool { systemSupported && runtimeSupported && snapshot?.isReady == true }
    var isActive: Bool { (snapshot?.activeCalls ?? 0) > 0 }
    var statusKey: String {
        if !systemSupported { return "computer_use.unsupported" }
        if !runtimeSupported { return "computer_use.runtime_unsupported" }
        if isLoading && snapshot == nil { return "computer_use.checking" }
        if snapshot?.pendingRestart == true { return "computer_use.waiting_restart" }
        if isTesting { return "computer_use.testing" }
        if isActive { return "computer_use.active" }
        switch snapshot?.status {
        case "ready": return "computer_use.ready"
        case "setupRequired": return "computer_use.setup_required"
        case "restarting": return "computer_use.restarting"
        case "error": return "computer_use.failed"
        case "unsupported": return "computer_use.unsupported"
        default: return "computer_use.disabled"
        }
    }

    func load(check: Bool = false, silent: Bool = false) async {
        guard systemSupported, !isRefreshing, !isWorking else { return }
        isRefreshing = true
        isLoading = !silent && (snapshot == nil || check)
        defer { isLoading = false; isRefreshing = false }
        do {
            let hello = try await service.start()
            runtimeSupported = hello.supportsPiWorkCapability(.computerUseGet)
                && hello.supportsPiWorkCapability(.computerUseAction)
            guard runtimeSupported else { snapshot = nil; return }
            snapshot = try await service.computerUseSnapshot(check: check)
            if !silent { errorMessage = snapshot?.error }
        } catch { if !silent { errorMessage = error.localizedDescription } }
    }

    func setEnabled(_ enabled: Bool) async {
        verification = nil
        await action(enabled ? "enable" : "disable")
    }

    func action(_ action: String, force: Bool = false) async {
        guard systemSupported, runtimeSupported, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        if action == "recheck" { verification = nil }
        defer { isWorking = false }
        do {
            snapshot = try await service.computerUseAction(action, force: force)
            errorMessage = snapshot?.error
        } catch { errorMessage = error.localizedDescription }
    }

    func test() async {
        guard isReady, !isTesting, !isActive else { return }
        isTesting = true
        verification = nil
        errorMessage = nil
        defer { isTesting = false }
        do {
            verification = try await service.verifyComputerUse()
            errorMessage = verification?.error
        } catch { errorMessage = error.localizedDescription }
        await load(silent: true)
    }
}
