import Darwin
import Foundation

enum AgentRuntimeHealth {
    static func validate(_ hello: AgentHostHelloPayload, manifest: AgentRuntimeManifest) throws {
        guard hello.runtime == AgentHostRuntimeInfo(
            version: manifest.version, apiVersion: manifest.apiVersion, piVersion: manifest.piVersion
        ), hello.piVersion == manifest.piVersion,
            AgentHostPiWorkCapability.all.isSubset(of: hello.piWorkCapabilities),
            hello.acpCapabilities.listSessions, hello.acpCapabilities.resumeSession,
            hello.acpCapabilities.closeSession, hello.acpCapabilities.promptImages
        else { throw AgentRuntimeError.incompatible }
    }

    static func probe(_ installation: AgentRuntimeInstallation) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await checkPackageManager(installation.bunURL, workingDirectory: scratch)
        let client = AgentHostClient(
            executableURL: installation.executableURL,
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PI_WORK_AGENT_DIR": scratch.path,
                "PI_CODING_AGENT_DIR": scratch.path,
                "PI_WORK_AUTH_PATH": scratch.appendingPathComponent("auth.json").path,
                "PI_WORK_BUN_PATH": installation.bunURL.path,
                "PI_WORK_SKIP_REQUIRED_EXTENSION_INSTALL": "1"
            ], handshakeTimeout: 15, workingDirectory: scratch, inheritEnvironment: false
        )
        do {
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try validate(try await client.start(), manifest: installation.manifest)
                let _: AgentHostSettings = try await client.request(
                    method: "settings.get", params: AgentHostEmptyParameters(), timeout: 15,
                    as: AgentHostSettings.self
                )
                // Initialize the embedded SDK/model catalog as well as the wire adapter.
                let _: AgentHostModelListResult = try await client.request(
                    method: "models.list", params: AgentHostEmptyParameters(), timeout: 15,
                    as: AgentHostModelListResult.self
                )
                try Task.checkCancellation()
            }, onCancel: { Task { await client.stop() } })
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    private static func checkPackageManager(_ executable: URL, workingDirectory: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.currentDirectoryURL = workingDirectory
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        for _ in 0..<50 where process.isRunning {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !process.isRunning, process.terminationStatus == 0 else { throw AgentRuntimeError.healthCheck }
    }
}

enum AgentRuntimeInstallPhase: Equatable {
    case downloading, verifying, testing
}

actor AgentRuntimeInstaller {
    private let store: AgentRuntimeStore
    private let session: URLSession
    private var installing = false

    init(store: AgentRuntimeStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    func check() async throws -> AgentRuntimeManifest? {
        let request = URLRequest(url: AgentRuntimeManifest.indexURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try await AgentRuntimeDownload.fetch(request, to: file, byteCount: 2 * 1024 * 1024,
                                             exactByteCount: false, configuration: session.configuration)
        return try JSONDecoder().decode(AgentRuntimeIndex.self, from: Data(contentsOf: file))
            .latestCompatible(appVersion: store.appVersion)
    }

    func install(
        _ manifest: AgentRuntimeManifest,
        progress: @escaping @Sendable (AgentRuntimeInstallPhase) async -> Void
    ) async throws {
        guard !installing else { throw AgentRuntimeError.busy }
        installing = true
        defer { installing = false }
        try manifest.validate()
        guard manifest.isCompatible(appVersion: store.appVersion) else { throw AgentRuntimeError.incompatible }
        let manager = FileManager.default
        let root = store.root
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        await progress(.downloading)
        let request = URLRequest(url: manifest.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 180)
        let archive = staging.appendingPathComponent("download.tar.gz")
        try await AgentRuntimeDownload.fetch(request, to: archive, byteCount: manifest.byteCount,
                                             configuration: session.configuration)
        await progress(.verifying)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        let candidate = AgentRuntimeInstallation(directory: payload, manifest: manifest)
        // Hashing and archive IO must not block the main actor or the service actor.
        try await Task.detached {
            guard try AgentRuntimeArchive.digest(of: archive) == manifest.sha256 else {
                throw AgentRuntimeError.integrity
            }
            try AgentRuntimeArchive.extract(archive, to: payload, manifest: manifest)
            try AgentRuntimeArchive.verify(candidate)
        }.value
        try Task.checkCancellation()
        await progress(.testing)
        try await AgentRuntimeHealth.probe(candidate)
        try Task.checkCancellation()
        try JSONEncoder().encode(manifest).write(to: payload.appendingPathComponent("installed.json"), options: .atomic)
        let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
        if manager.fileExists(atPath: destination.path) {
            if let existing = try? await store.installation(manifest.id) {
                guard existing.manifest == manifest else { throw AgentRuntimeError.integrity }
                let intact = (try? await Task.detached {
                    try AgentRuntimeArchive.verify(existing)
                    return true
                }.value) == true
                if intact {
                    try await store.stage(existing)
                    return
                }
            }
            // A failed/corrupt cached candidate can be reinstalled. Never replace
            // the running version or the version reserved for rollback.
            let state = try await store.selection()
            guard state.active != manifest.id, state.previous != manifest.id else {
                throw AgentRuntimeError.integrity
            }
            try Task.checkCancellation()
            _ = try manager.replaceItemAt(destination, withItemAt: payload, options: .usingNewMetadataOnly)
            try await store.stage(AgentRuntimeInstallation(directory: destination, manifest: manifest))
        } else {
            try manager.moveItem(at: payload, to: destination)
            try await store.stage(AgentRuntimeInstallation(directory: destination, manifest: manifest))
        }
    }
}
