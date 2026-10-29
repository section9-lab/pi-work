import Foundation

struct ComputerUsePermissions: Codable, Equatable {
    let accessibility: Bool
    let screenRecording: Bool
    let screenRecordingPreflight: Bool
    let attribution: String
}

struct ComputerUseSnapshot: Codable, Equatable {
    let supported: Bool
    let enabled: Bool
    let status: String
    let permissions: ComputerUsePermissions
    let helperPath: String
    let activeCalls: Int
    let pendingRestart: Bool
    let generation: Int
    let error: String?

    var isReady: Bool { supported && enabled && status == "ready" && !pendingRestart }
}

struct ComputerUseGetParameters: Encodable { var check = false }
struct ComputerUseActionParameters: Encodable {
    let action: String
    var force = false
}

struct ComputerUseVerification: Decodable, Equatable {
    let observed: Bool
    let acted: Bool
    let verified: Bool
    let error: String?
}

protocol ComputerUseServicing: Actor {
    func start() async throws -> AgentHostHelloPayload
    func computerUseSnapshot(check: Bool) async throws -> ComputerUseSnapshot
    func computerUseAction(_ action: String, force: Bool) async throws -> ComputerUseSnapshot
    func verifyComputerUse() async throws -> ComputerUseVerification
}

extension AgentHostService: ComputerUseServicing {
    func computerUseSnapshot(check: Bool = false) async throws -> ComputerUseSnapshot {
        try await request(id: UUID().uuidString, method: "computerUse.get",
                          params: ComputerUseGetParameters(check: check), timeout: 60, as: ComputerUseSnapshot.self)
    }

    func computerUseAction(_ action: String, force: Bool = false) async throws -> ComputerUseSnapshot {
        try await request(id: UUID().uuidString, method: "computerUse.action",
                          params: ComputerUseActionParameters(action: action, force: force), timeout: 60, as: ComputerUseSnapshot.self)
    }

    func verifyComputerUse() async throws -> ComputerUseVerification {
        try await request(id: UUID().uuidString, method: "computerUse.verify",
                          params: AgentHostEmptyParameters(), timeout: 90, as: ComputerUseVerification.self)
    }
}
