import Combine
import Foundation

@MainActor
final class MCPStore: ObservableObject {
    @Published private(set) var servers: [MCPServer] = []
    @Published private(set) var configurationErrors: [String] = []
    @Published private(set) var authentication: MCPAuthentication?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSupported = true
    @Published var errorMessage: String?
    private let service: any MCPServicing
    private var lastOpenedAuthorizationURL: String?

    init(service: any MCPServicing) { self.service = service }

    func load(silent: Bool = false, recheck: Bool = false) async {
        guard !isLoading, !isWorking else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let hello = try await service.start()
            isSupported = hello.supportsPiWorkCapability(.mcpList)
            guard isSupported else { servers = []; return }
            let previousAuth = authentication
            apply(try await service.mcpSnapshot())
            if !silent { errorMessage = nil }
            let signedIn = authentication?.state == "success" && authentication != previousAuth
            await checkUnverifiedServers(recheck: recheck, authenticatedServer: signedIn ? authentication?.name : nil)
        } catch {
            if !silent { errorMessage = error.localizedDescription }
        }
    }

    func save(_ parameters: MCPSaveParameters) async -> Bool {
        await perform { try await self.service.saveMCP(parameters) }
    }

    func importConfiguration(_ json: String) async -> Bool {
        await perform { try await self.service.importMCP(json) }
    }

    func action(_ action: String, server: MCPServer, redirectURL: String? = nil) async {
        _ = await perform {
            try await self.service.performMCPAction(MCPActionParameters(name: server.name, action: action, redirectURL: redirectURL))
        }
    }

    /// Only URLs returned by a user-initiated OAuth flow may open the browser.
    func takeAuthorizationURL() -> URL? {
        guard authentication?.state == "authorizing",
              let value = authentication?.url, value != lastOpenedAuthorizationURL,
              let url = Self.webURL(value) else { return nil }
        lastOpenedAuthorizationURL = value
        return url
    }

    nonisolated static func webURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              let url = parts.url else { return nil }
        return url
    }

    private func perform(_ operation: () async throws -> MCPSnapshot) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            apply(try await operation())
            await checkUnverifiedServers()
            return true
        }
        catch { errorMessage = error.localizedDescription; return false }
    }

    /// Checks only approved, enabled configurations. The Host starts each probe
    /// asynchronously; polling reads its result without executing any tools.
    private func checkUnverifiedServers(recheck: Bool = false, authenticatedServer: String? = nil) async {
        let candidates = servers.filter {
            $0.enabled && $0.status != "connecting"
                && ($0.status == "unchecked" || recheck || $0.name == authenticatedServer)
        }
        for server in candidates {
            guard !Task.isCancelled else { return }
            do { apply(try await service.performMCPAction(MCPActionParameters(name: server.name, action: "check"))) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func apply(_ snapshot: MCPSnapshot) {
        servers = snapshot.servers
        configurationErrors = snapshot.errors
        authentication = snapshot.auth
    }
}
