import Foundation

struct MCPMarketPage: Codable, Equatable, Sendable {
    var items: [MCPMarketPreset]
    var nextCursor: String?
    var isCached = false
}

protocol MCPRegistryLoading: Sendable {
    func page(search: String, cursor: String?) async throws -> MCPMarketPage
}

/// Official registry JSON is decoded separately from native MCP configuration.
/// Unsupported transports remain discoverable, but cannot become executable recipes.
struct MCPRegistryResponse: Decodable {
    var servers: [Entry]
    var metadata: Metadata?
    struct Metadata: Decodable { var nextCursor: String? }
    struct Entry: Decodable { var server: Server }
    struct Server: Decodable {
        var name: String
        var title: String?
        var description: String?
        var version: String?
        var websiteUrl: String?
        var repository: Repository?
        var icons: [Icon]?
        var remotes: [Remote]?
        var packages: [Package]?
    }
    struct Repository: Decodable { var url: String? }
    struct Icon: Decodable { var src: String; var mimeType: String? }
    struct Remote: Decodable { var type: String; var url: String; var headers: [Input]? }
    struct Package: Decodable {
        var registryType: String
        var identifier: String
        var version: String?
        var transport: Transport?
        var runtimeArguments: [Argument]?
        var packageArguments: [Argument]?
        var environmentVariables: [Input]?
    }
    struct Transport: Decodable { var type: String }
    struct Input: Decodable {
        var name: String
        var value: String?
        var `default`: String?
        var description: String?
        var isRequired: Bool?
        var isSecret: Bool?
    }
    struct Argument: Decodable {
        var type: String?
        var name: String?
        var value: String?
        var `default`: String?
        var valueHint: String?
        var isRequired: Bool?
    }

    func page() -> MCPMarketPage {
        var seen = Set<String>()
        let items = servers.compactMap { entry -> MCPMarketPreset? in
            let server = entry.server
            guard !server.name.isEmpty, seen.insert(server.name).inserted else { return nil }
            let repository = server.repository?.url.flatMap(MCPMarketURL.publicHTTPS)
            let owner = repository.flatMap { $0.host?.lowercased() == "github.com" ? $0.pathComponents.dropFirst().first : nil }
            let publisher = owner ?? server.name.split(separator: "/").first.map(String.init) ?? server.name
            var icons = (server.icons ?? []).compactMap { MCPMarketURL.publicHTTPS($0.src) }
            if let owner, let avatar = URL(string: "https://avatars.githubusercontent.com/\(owner)?s=96") {
                icons.append(avatar)
            }
            let website = server.websiteUrl.flatMap(MCPMarketURL.publicHTTPS)
            let docs = website ?? repository ?? URL(string: "https://registry.modelcontextprotocol.io")!
            var preset = MCPMarketPreset(id: server.name,
                name: server.title.flatMap { $0.isEmpty ? nil : $0 } ?? server.name.split(separator: "/").last.map(String.init) ?? server.name,
                publisher: publisher, summary: server.description ?? "", connection: .unsupported,
                documentationURL: docs.absoluteString, iconURLs: icons.reduce(into: [URL]()) { result, url in
                    if !result.contains(url) { result.append(url) }
                }, version: server.version ?? "")
            if let remote = server.remotes?.first(where: {
                $0.type == "streamable-http" && MCPStore.webURL($0.url) != nil
            }) {
                preset = replacingConnection(preset, .http(remote.url))
                for input in remote.headers ?? [] {
                    preset.headers[input.name] = input.isSecret == true ? "" : input.value ?? input.default ?? ""
                    if input.isRequired == true || preset.headers[input.name]?.contains("{") == true {
                        preset.setupNotes.append(input.description ?? input.name)
                    }
                }
                if remote.url.contains("{") { preset.setupNotes.append(remote.url) }
                return preset
            }
            guard let package = server.packages?.first(where: {
                ["npm", "pypi"].contains($0.registryType) && ($0.transport == nil || $0.transport?.type == "stdio")
            }), !package.identifier.isEmpty, !package.identifier.hasPrefix("-") else { return preset }
            let isNPM = package.registryType == "npm"
            let version = package.version.flatMap { $0.isEmpty || $0 == "latest" ? nil : $0 }
            let identifier = package.identifier + (version.map { (isNPM ? "@" : "==") + $0 } ?? "")
            var arguments = argumentValues(package.runtimeArguments ?? [], notes: &preset.setupNotes)
            if isNPM, !arguments.contains("-y"), !arguments.contains("--yes") { arguments.insert("-y", at: 0) }
            arguments.append(identifier)
            // Preserve both argument groups in the editable recipe. They are
            // never executed until the user confirms the configuration editor.
            if package.runtimeArguments?.isEmpty == false {
                preset.setupNotes.append(L10n.string("mcp.market.runtime_review"))
            }
            arguments += argumentValues(package.packageArguments ?? [], notes: &preset.setupNotes)
            preset = replacingConnection(preset, .stdio(command: isNPM ? "npx" : "uvx", arguments: arguments))
            for input in package.environmentVariables ?? [] {
                preset.environment[input.name] = input.isSecret == true ? "" : input.value ?? input.default ?? ""
                if input.isRequired == true { preset.setupNotes.append(input.description ?? input.name) }
            }
            return preset
        }
        return MCPMarketPage(items: items, nextCursor: metadata?.nextCursor.flatMap { $0.isEmpty ? nil : $0 })
    }

    private func argumentValues(_ arguments: [Argument], notes: inout [String]) -> [String] {
        var result: [String] = []
        for argument in arguments {
            let value = argument.value ?? argument.default
            guard value != nil || argument.isRequired == true else { continue }
            if let name = argument.name, argument.type == "named" { result.append(name) }
            if let value {
                result.append(value)
                if value.contains("{") { notes.append(value) }
            } else if argument.valueHint != nil || argument.type != "named" {
                let placeholder = "<\(argument.valueHint ?? argument.name ?? "value")>"
                result.append(placeholder)
                notes.append(placeholder)
            }
        }
        return result
    }

    private func replacingConnection(_ preset: MCPMarketPreset, _ connection: MCPMarketPreset.Connection) -> MCPMarketPreset {
        MCPMarketPreset(id: preset.id, name: preset.name, publisher: preset.publisher, summary: preset.summary,
            connection: connection, requiresLogin: preset.requiresLogin, documentationURL: preset.documentationURL,
            iconURLs: preset.iconURLs, version: preset.version, environment: preset.environment,
            headers: preset.headers, setupNotes: preset.setupNotes)
    }
}

/// Never load local files, credentials-bearing URLs or private IP literals as artwork.
/// Registry requests themselves always target the fixed official HTTPS endpoint.
enum MCPMarketURL {
    static func publicHTTPS(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, let host = parts.host?.lowercased(),
              !host.isEmpty, ![".local", ".localhost", ".internal", ".lan", ".home"].contains(where: host.hasSuffix),
              host.range(of: #"^[a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else { return nil }
        // Artwork uses DNS names only. This also excludes alternate integer,
        // shortened, hexadecimal and IPv6 spellings of loopback/private IPs.
        return parts.url
    }
}

private final class MCPRegistryRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && request.url?.host == "registry.modelcontextprotocol.io"
        completionHandler(allowed ? request : nil)
    }
}

actor MCPRegistryClient: MCPRegistryLoading {
    private let session: URLSession
    private let cacheURL: URL?
    private let maximumBytes = 4 * 1024 * 1024

    init(session: URLSession? = nil, cacheURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("cc.vibevibe.pi-work/mcp-registry.json")) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: MCPRegistryRedirects(), delegateQueue: nil)
        self.cacheURL = cacheURL
    }

    static func requestURL(search: String, cursor: String?) -> URL {
        var parts = URLComponents(string: "https://registry.modelcontextprotocol.io/v0.1/servers")!
        parts.queryItems = [URLQueryItem(name: "version", value: "latest"), URLQueryItem(name: "limit", value: "48")]
        if search.count >= 3 { parts.queryItems?.append(URLQueryItem(name: "search", value: search)) }
        if let cursor { parts.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        return parts.url!
    }

    func page(search: String, cursor: String?) async throws -> MCPMarketPage {
        do {
            let (data, response) = try await session.data(from: Self.requestURL(search: search, cursor: cursor))
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url?.host == "registry.modelcontextprotocol.io", data.count <= maximumBytes else {
                throw URLError(.badServerResponse)
            }
            let page = try JSONDecoder().decode(MCPRegistryResponse.self, from: data).page()
            if search.isEmpty, cursor == nil, let cacheURL {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
            return page
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // A failed search never masquerades as a successful empty-query page.
            if search.isEmpty, cursor == nil, let cacheURL,
               let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes,
               let data = try? Data(contentsOf: cacheURL),
               var cached = try? JSONDecoder().decode(MCPRegistryResponse.self, from: data).page() {
                cached.isCached = true
                cached.nextCursor = nil
                return cached
            }
            throw error
        }
    }
}
