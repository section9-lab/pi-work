import Combine
import Foundation

/// Read-only version information for the agent bundled and released with PiWork.
@MainActor
final class AgentRuntimeUpdateController: ObservableObject {
    @Published private(set) var currentPiVersion: String
    @Published private(set) var currentRuntimeVersion: String

    private let service: AgentHostService
    private var lifecycleTask: Task<Void, Never>?

    init(service: AgentHostService) {
        self.service = service
        currentPiVersion = AgentHostExecutable.piCodingAgentVersion() ?? ""
        currentRuntimeVersion = AgentHostExecutable.runtimeVersion() ?? "0.0.0"
    }

    deinit { lifecycleTask?.cancel() }

    func start() async {
        guard lifecycleTask == nil else { return }
        let events = await service.lifecycleEvents()
        lifecycleTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case let .connected(_, hello), let .restarted(_, hello):
                    updateVersion(hello)
                case .disconnected: break
                }
            }
        }
        if let hello = try? await service.start() {
            updateVersion(hello)
        }
    }

    private func updateVersion(_ hello: AgentHostHelloPayload) {
        if hello.piVersion != "unknown" { currentPiVersion = hello.piVersion }
        currentRuntimeVersion = hello.runtime?.version ?? AgentHostExecutable.runtimeVersion() ?? "0.0.0"
    }
}
