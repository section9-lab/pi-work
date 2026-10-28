import Combine
import Foundation

@MainActor
final class AgentRuntimeUpdateController: ObservableObject {
    @Published private(set) var currentPiVersion: String
    @Published private(set) var currentRuntimeVersion: String
    @Published private(set) var availableUpdate: AgentRuntimeManifest?
    @Published private(set) var isChecking = false
    @Published private(set) var phase: AgentRuntimeInstallPhase?
    @Published private(set) var didCheck = false
    @Published private(set) var pendingPiVersion: String?
    @Published private(set) var canRollback = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var rollbackMessage: String?

    private let store: AgentRuntimeStore
    private let installer: AgentRuntimeInstaller
    private let service: AgentHostService
    private var lifecycleTask: Task<Void, Never>?

    var isBusy: Bool { isChecking || phase != nil }

    init(store: AgentRuntimeStore, service: AgentHostService) {
        self.store = store
        self.service = service
        installer = AgentRuntimeInstaller(store: store)
        currentPiVersion = AgentHostExecutable.piCodingAgentVersion() ?? ""
        currentRuntimeVersion = AgentHostExecutable.runtimeVersion() ?? "0.0.0"
    }

    deinit { lifecycleTask?.cancel() }

    func start() async {
        if lifecycleTask == nil {
            let events = await service.lifecycleEvents()
            lifecycleTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    switch event {
                    case let .connected(_, hello), let .restarted(_, hello):
                        updateVersion(hello)
                        await refreshSelection()
                    case .disconnected: break
                    }
                }
            }
        }
        do { updateVersion(try await service.start()) } catch { errorMessage = error.localizedDescription }
        await refreshSelection()
    }

    func checkForUpdates() async {
        guard !isBusy else { return }
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        do {
            let latest = try await installer.check()
            guard let latest else { throw AgentRuntimeError.incompatible }
            if let installed = ReleaseVersion(currentRuntimeVersion),
               let offered = ReleaseVersion(latest.version), offered > installed {
                availableUpdate = latest
            } else {
                availableUpdate = nil
            }
            didCheck = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func installUpdate() async {
        guard !isBusy, let availableUpdate else { return }
        phase = .downloading
        errorMessage = nil
        defer { phase = nil }
        do {
            try await installer.install(availableUpdate) { [weak self] phase in
                await self?.setPhase(phase)
            }
            self.availableUpdate = nil
            await refreshSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelPending() async {
        guard !isBusy else { return }
        do {
            try await store.cancelPending()
            errorMessage = nil
            await refreshSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    func rollback() async {
        guard !isBusy, canRollback else { return }
        do {
            try await store.stageRollback()
            errorMessage = nil
            await refreshSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    private func setPhase(_ phase: AgentRuntimeInstallPhase) { self.phase = phase }

    private func updateVersion(_ hello: AgentHostHelloPayload) {
        if hello.piVersion != "unknown" { currentPiVersion = hello.piVersion }
        currentRuntimeVersion = hello.runtime?.version ?? AgentHostExecutable.runtimeVersion() ?? "0.0.0"
    }

    private func refreshSelection() async {
        do {
            let state = try await store.selection()
            canRollback = state.active != nil
            rollbackMessage = state.lastFailure
            if let pending = state.pending {
                pendingPiVersion = pending == "bundled"
                    ? AgentHostExecutable.piCodingAgentVersion() ?? ""
                    : try await store.installation(pending).manifest.piVersion
            } else {
                pendingPiVersion = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
