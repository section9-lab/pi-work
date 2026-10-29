import Foundation

struct MCPTool: Decodable, Equatable, Identifiable {
    let name: String
    let callName: String
    let description: String
    let readOnly: Bool
    var id: String { name }
}

struct MCPServer: Decodable, Equatable, Identifiable {
    let name: String
    let transport: String
    let enabled: Bool
    let configurationJSON: String
    let allowInChat: Bool
    let readOnlyTools: [String]
    let status: String
    let tools: [MCPTool]
    let error: String?
    let canLogin: Bool
    let signedIn: Bool
    var id: String { name }
}

struct MCPAuthentication: Decodable, Equatable {
    let name: String
    let state: String
    let url: String?
    let error: String?
}

struct MCPSnapshot: Decodable, Equatable {
    let servers: [MCPServer]
    let errors: [String]
    let auth: MCPAuthentication?
}

struct MCPSaveParameters: Encodable {
    let name: String
    let configurationJSON: String
    let allowInChat: Bool
    let readOnlyTools: [String]
}

struct MCPImportParameters: Encodable {
    let configurationJSON: String
}

struct MCPActionParameters: Encodable {
    let name: String
    let action: String
    var redirectURL: String? = nil
}

protocol MCPServicing: Actor {
    func start() async throws -> AgentHostHelloPayload
    func mcpSnapshot() async throws -> MCPSnapshot
    func saveMCP(_ parameters: MCPSaveParameters) async throws -> MCPSnapshot
    func importMCP(_ configurationJSON: String) async throws -> MCPSnapshot
    func performMCPAction(_ parameters: MCPActionParameters) async throws -> MCPSnapshot
}

extension AgentHostService {
    func mcpSnapshot() async throws -> MCPSnapshot {
        try await request(id: UUID().uuidString, method: "mcp.list",
                          params: AgentHostEmptyParameters(), as: MCPSnapshot.self)
    }

    func saveMCP(_ parameters: MCPSaveParameters) async throws -> MCPSnapshot {
        try await request(id: UUID().uuidString, method: "mcp.save", params: parameters, as: MCPSnapshot.self)
    }

    func importMCP(_ configurationJSON: String) async throws -> MCPSnapshot {
        try await request(id: UUID().uuidString, method: "mcp.import",
                          params: MCPImportParameters(configurationJSON: configurationJSON), as: MCPSnapshot.self)
    }

    func performMCPAction(_ parameters: MCPActionParameters) async throws -> MCPSnapshot {
        try await request(id: UUID().uuidString, method: "mcp.action", params: parameters, as: MCPSnapshot.self)
    }
}
