import Foundation

struct RTKGain: Codable, Equatable {
    let commands: Int
    let input: Double
    let saved: Double
    let pct: Double
}

struct RTKDay: Codable, Equatable, Identifiable {
    let date: String
    let commands: Int
    let input: Double
    let saved: Double
    let pct: Double
    var id: String { date }

    var calendarDate: Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

struct RTKSnapshot: Codable, Equatable {
    let supported: Bool
    let enabled: Bool
    let path: String?
    let version: String?
    let latestVersion: String?
    let gain: RTKGain?
    let days: [RTKDay]
    let statsError: String?
    let updateError: String?

    var updateAvailable: Bool {
        guard let version, let latestVersion else { return false }
        return version.compare(latestVersion, options: .numeric) == .orderedAscending
    }
}

struct RTKGetParameters: Encodable { var checkLatest = false }
struct RTKActionParameters: Encodable { let action: String }

protocol RTKServicing: Actor {
    func start() async throws -> AgentHostHelloPayload
    func rtkSnapshot(checkLatest: Bool) async throws -> RTKSnapshot
    func rtkAction(_ action: String) async throws -> RTKSnapshot
}

extension AgentHostService: RTKServicing {
    func rtkSnapshot(checkLatest: Bool = false) async throws -> RTKSnapshot {
        try await request(id: UUID().uuidString, method: "rtk.get", params: RTKGetParameters(checkLatest: checkLatest),
                          timeout: 75, as: RTKSnapshot.self)
    }

    func rtkAction(_ action: String) async throws -> RTKSnapshot {
        try await request(id: UUID().uuidString, method: "rtk.action", params: RTKActionParameters(action: action),
                          timeout: 300, as: RTKSnapshot.self)
    }
}
