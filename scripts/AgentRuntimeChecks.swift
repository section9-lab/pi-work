import Foundation

private final class RuntimeURLProtocol: URLProtocol {
    static var index = Data()
    static var archive = Data()
    static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.url!.lastPathComponent == "runtime-index.json" ? Self.index : Self.archive
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
                                       httpVersion: nil, headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Run against production sources with the Command Line Tools as well as Xcode.
/// This keeps recovery and archive checks available without an XCTest host app.
@main
struct AgentRuntimeChecks {
    struct Failure: Error { let message: String }
    static var checks = 0

    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        checks += 1
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { checks += 1; return }
        throw Failure(message: message)
    }

    static func rejectsAsync(_ message: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { checks += 1; return }
        throw Failure(message: message)
    }

    static func changed(_ manifest: AgentRuntimeManifest, _ patch: [String: Any]) throws -> AgentRuntimeManifest {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        object.merge(patch) { _, new in new }
        return try JSONDecoder().decode(AgentRuntimeManifest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func main() async {
        do { try await run() } catch {
            fputs("Agent runtime failed after \(checks) checks: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manifestURL = root.appendingPathComponent("runtime-\(AppArchitecture.current.rawValue).json")
        let manifest = try JSONDecoder().decode(AgentRuntimeManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        try expect(manifest.isCompatible(appVersion: "0.1.10"), "compatible runtime rejected")
        try expect(!manifest.isCompatible(appVersion: "0.1.8"), "minimum app version ignored")
        try expect(!manifest.isCompatible(appVersion: "0.1.10", macOSVersion: "12.0"), "OS requirement ignored")
        try expect(!(try changed(manifest, ["apiVersion": 2])).isCompatible(appVersion: "0.1.10"), "API version ignored")
        try expect(!(try changed(manifest, ["acpVersion": 2])).isCompatible(appVersion: "0.1.10"), "ACP version ignored")
        try expect(!(try changed(manifest, ["maximumAppVersion": "0.2.0"])).isCompatible(appVersion: "0.3.0"), "upper app bound ignored")
        let other: AppArchitecture = AppArchitecture.current == .arm64 ? .x86_64 : .arm64
        try expect(!manifest.isCompatible(appVersion: "0.1.10", architecture: other), "architecture ignored")
        for patch: [String: Any] in [
            ["url": "https://evil.example/runtime.tar.gz"], ["sha256": "bad"],
            ["version": "../outside"], ["byteCount": 0], ["schemaVersion": 2],
            ["files": ["../outside": String(repeating: "a", count: 64)]]
        ] {
            try rejects("invalid manifest accepted") { try changed(manifest, patch).validate() }
        }
        let newer = try changed(manifest, ["version": "1.10.0", "url": AgentRuntimeManifest.repository
            + "runtime-v1.10.0/PiWorkRuntime-1.10.0-macos-\(manifest.architecture).tar.gz"])
        let incompatible = try changed(newer, ["minimumAppVersion": "9.0.0"])
        try expect(try AgentRuntimeIndex(schemaVersion: 1, releases: [incompatible, manifest])
            .latestCompatible(appVersion: "0.1.10") == manifest, "feed offered incompatible latest")
        try expect(try AgentRuntimeIndex(schemaVersion: 1, releases: [manifest, newer])
            .latestCompatible(appVersion: "0.1.10") == newer, "feed order affected numeric comparison")

        let archive = root.appendingPathComponent(manifest.url.lastPathComponent)
        try expect(try AgentRuntimeArchive.digest(of: archive) == manifest.sha256, "archive digest mismatch")
        let payload = root.appendingPathComponent("verified")
        try AgentRuntimeArchive.extract(archive, to: payload, manifest: manifest)
        let installed = AgentRuntimeInstallation(directory: payload, manifest: manifest)
        try AgentRuntimeArchive.verify(installed)
        checks += 1
        for kind in ["traversal", "symlink", "hardlink", "duplicate", "oversized", "absolute", "reserved"] {
            try rejects("unsafe \(kind) archive accepted") {
                try AgentRuntimeArchive.extract(root.appendingPathComponent("\(kind).tar.gz"),
                                                to: root.appendingPathComponent(kind), manifest: manifest)
            }
        }
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path), "archive escaped staging")
        let resource = payload.appendingPathComponent("theme/theme.json")
        let original = try Data(contentsOf: resource)
        try Data("tampered".utf8).write(to: resource)
        try rejects("tampered resource accepted") { try AgentRuntimeArchive.verify(installed) }
        try original.write(to: resource)
        let extra = payload.appendingPathComponent("unexpected")
        try Data().write(to: extra)
        try rejects("unexpected payload file accepted") { try AgentRuntimeArchive.verify(installed) }
        try FileManager.default.removeItem(at: extra)

        let executableBytes = try Data(contentsOf: installed.executableURL)
        var brokenExecutable = executableBytes
        // Change a signed text page, leaving the Mach-O architecture header intact.
        brokenExecutable[4096] ^= 0xff
        try brokenExecutable.write(to: installed.executableURL)
        var changedFiles = manifest.files
        changedFiles[AgentHostExecutable.filename] = try AgentRuntimeArchive.digest(of: installed.executableURL)
        let badSignature = AgentRuntimeInstallation(directory: payload,
            manifest: try changed(manifest, ["files": changedFiles]))
        try rejects("invalid code signature accepted despite matching file hashes") {
            try AgentRuntimeArchive.verify(badSignature)
        }
        try executableBytes.write(to: installed.executableURL)
        try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: resource)
        try rejects("symlink in installed runtime accepted") { try AgentRuntimeArchive.verify(installed) }
        try FileManager.default.removeItem(at: extra)

        let storeRoot = root.appendingPathComponent("store")
        let store = AgentRuntimeStore(root: storeRoot, appVersion: "0.1.10")
        _ = try await store.beginLaunch()
        let storedDirectory = storeRoot.appendingPathComponent(manifest.id, isDirectory: true)
        try FileManager.default.copyItem(at: payload, to: storedDirectory)
        try JSONEncoder().encode(manifest).write(to: storedDirectory.appendingPathComponent("installed.json"))
        let stored = AgentRuntimeInstallation(directory: storedDirectory, manifest: manifest)
        try await store.stage(stored)
        try expect(try await store.beginLaunch() == nil, "staging changed the running launch")
        let nextLaunch = AgentRuntimeStore(root: storeRoot, appVersion: "0.1.10")
        try expect(try await nextLaunch.beginLaunch() == stored, "pending runtime not selected on next launch")
        try expect(try await nextLaunch.selection().trial == manifest.id, "trial marker missing")
        // Simulate an app termination before the candidate's handshake completed.
        let interrupted = AgentRuntimeStore(root: storeRoot, appVersion: "0.1.10")
        try expect(try await interrupted.beginLaunch() == nil, "interrupted trial was not rolled back")
        try await interrupted.stage(stored)
        let confirmed = AgentRuntimeStore(root: storeRoot, appVersion: "0.1.10")
        _ = try await confirmed.beginLaunch()
        try await confirmed.confirm(manifest.id)
        try expect(try await confirmed.selection().trial == nil, "healthy candidate was not confirmed")
        let restarted = AgentRuntimeStore(root: storeRoot, appVersion: "0.1.10")
        try expect(try await restarted.beginLaunch() == stored, "confirmed runtime did not survive restart")
        let newerDirectory = storeRoot.appendingPathComponent(newer.id, isDirectory: true)
        try FileManager.default.copyItem(at: payload, to: newerDirectory)
        try JSONEncoder().encode(newer).write(to: newerDirectory.appendingPathComponent("installed.json"))
        let newerInstallation = AgentRuntimeInstallation(directory: newerDirectory, manifest: newer)
        try await restarted.stage(newerInstallation)
        let newerLaunch = AgentRuntimeStore(root: storeRoot, appVersion: "0.1.10")
        try expect(try await newerLaunch.beginLaunch() == newerInstallation, "new candidate not selected")
        try expect(try await newerLaunch.selection().previous == manifest.id, "previous version not retained")
        try expect(try await newerLaunch.reject(newer.id, reason: "failed startup") == stored, "previous version not restored")
        try await restarted.stageRollback()
        let manualRollback = AgentRuntimeStore(root: storeRoot, appVersion: "0.1.10")
        try expect(try await manualRollback.beginLaunch() == nil, "manual bundled rollback failed")
        try await manualRollback.stage(stored)
        try await manualRollback.cancelPending()
        try expect(try await manualRollback.selection().pending == nil, "cancelled update remained pending")

        // A signed executable that exits immediately must fall back to the bundled host.
        try await manualRollback.stage(stored)
        let fallbackStore = AgentRuntimeStore(root: storeRoot, appVersion: "0.1.10")
        let initialize = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentInfo":{"name":"bundled-fixture","version":"fallback"}}}"#
        let service = AgentHostService(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' '\(initialize)'; cat >/dev/null"],
            handshakeTimeout: 1, runtimeStore: fallbackStore)
        let hello = try await service.start()
        try expect(hello.hostVersion == "fallback", "startup failure did not start bundled runtime")
        try expect(try await fallbackStore.selection().active == nil, "failed candidate stayed active")
        await service.stop()

        let fixtureManifest = try JSONDecoder().decode(AgentRuntimeManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("fixture-release/runtime-\(manifest.architecture).json")))
        let fixtureDirectory = storeRoot.appendingPathComponent(fixtureManifest.id, isDirectory: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("fixture-source"), to: fixtureDirectory)
        try JSONEncoder().encode(fixtureManifest).write(to: fixtureDirectory.appendingPathComponent("installed.json"))
        try await fallbackStore.stage(AgentRuntimeInstallation(directory: fixtureDirectory, manifest: fixtureManifest))
        let crashStore = AgentRuntimeStore(root: storeRoot, appVersion: "0.1.10")
        let crashService = AgentHostService(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' '\(initialize)'; cat >/dev/null"],
            environment: ["PI_WORK_TEST_CRASH": "1"],
            handshakeTimeout: 1, runtimeStore: crashStore)
        let initial = try await crashService.start()
        try expect(initial.runtime?.version == fixtureManifest.version, "verified external runtime not started")
        try rejects("wrong runtime handshake accepted") {
            try AgentRuntimeHealth.validate(AgentHostHelloPayload(
                hostVersion: initial.hostVersion, piVersion: initial.piVersion, capabilities: [],
                acpCapabilities: initial.acpCapabilities, piWorkCapabilities: initial.piWorkCapabilities,
                runtime: AgentHostRuntimeInfo(version: fixtureManifest.version, apiVersion: 2, piVersion: initial.piVersion)
            ), manifest: fixtureManifest)
        }
        try rejects("missing handshake capabilities accepted") {
            try AgentRuntimeHealth.validate(AgentHostHelloPayload(
                hostVersion: initial.hostVersion, piVersion: initial.piVersion, capabilities: [],
                acpCapabilities: initial.acpCapabilities, piWorkCapabilities: [], runtime: initial.runtime
            ), manifest: fixtureManifest)
        }
        try expect(try await crashStore.selection().trial == nil, "real process health not confirmed")
        let lifecycle = await crashService.lifecycleEvents()
        _ = try? await crashService.listModels()
        let recovered = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await event in lifecycle {
                    if case let .restarted(_, hello) = event { return hello.hostVersion }
                }
                throw Failure(message: "lifecycle ended without recovery")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw Failure(message: "runtime crash recovery timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        try expect(recovered == "fallback", "runtime exit did not recover to bundled host")
        try expect(try await crashStore.selection().active == nil, "crashed runtime stayed selected")
        await crashService.stop()

        // Exercise the entire HTTP download/install transaction with the normal
        // URLSession delegate, hash/signature checks and native process probe.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeURLProtocol.self]
        RuntimeURLProtocol.index = try JSONEncoder().encode(AgentRuntimeIndex(schemaVersion: 1, releases: [fixtureManifest]))
        RuntimeURLProtocol.archive = try Data(contentsOf: root.appendingPathComponent("fixture-release")
            .appendingPathComponent(fixtureManifest.url.lastPathComponent))
        let networkStore = AgentRuntimeStore(root: root.appendingPathComponent("download-store"), appVersion: "0.1.10")
        _ = try await networkStore.beginLaunch()
        let installer = AgentRuntimeInstaller(store: networkStore,
                                             session: URLSession(configuration: configuration))
        try expect(try await installer.check() == fixtureManifest, "runtime feed did not select compatible artifact")
        setenv("PI_WORK_PROBE_LEAK_TEST", "must-not-reach-candidate", 1)
        do { try await installer.install(fixtureManifest) { _ in } } catch {
            unsetenv("PI_WORK_PROBE_LEAK_TEST")
            throw error
        }
        unsetenv("PI_WORK_PROBE_LEAK_TEST")
        try expect(try await networkStore.selection().pending == fixtureManifest.id, "verified download not staged")
        try expect(try await networkStore.beginLaunch() == nil, "download interrupted the active runtime")
        try await rejectsAsync("bad archive digest was accepted") {
            try await installer.install(changed(fixtureManifest, ["sha256": String(repeating: "0", count: 64)])) { _ in }
        }
        try expect(try await networkStore.selection().pending == fixtureManifest.id, "failed download altered selection")
        RuntimeURLProtocol.archive.append(0)
        try await rejectsAsync("oversized download was accepted") {
            try await installer.install(fixtureManifest) { _ in }
        }
        RuntimeURLProtocol.statusCode = 503
        try await rejectsAsync("HTTP server error was accepted") { _ = try await installer.check() }
        RuntimeURLProtocol.statusCode = 200
        RuntimeURLProtocol.archive.removeLast()
        let damagedCache = try await networkStore.installation(fixtureManifest.id)
        try Data("damaged cache".utf8).write(to: damagedCache.directory.appendingPathComponent("theme/theme.json"))
        try await installer.install(fixtureManifest) { _ in }
        try AgentRuntimeArchive.verify(try await networkStore.installation(fixtureManifest.id))
        checks += 1
        try expect(!AgentRuntimeDownload.isTrusted(URL(string: "http://github.com/file")!), "HTTP download trusted")
        try expect(!AgentRuntimeDownload.isTrusted(URL(string: "https://github.com.evil.example/file")!), "foreign download trusted")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await AgentRuntimeDownload.fetch(URLRequest(url: fixtureManifest.url),
                to: root.appendingPathComponent("cancelled-download"), byteCount: fixtureManifest.byteCount,
                configuration: configuration)
        }
        try await rejectsAsync("cancelled download did not stop") { try await cancelled.value }
        try expect(try FileManager.default.contentsOfDirectory(atPath: networkStore.root.path)
            .allSatisfy { !$0.hasPrefix(".staging-") }, "failed transaction left staging data")

        // Check the real publisher artifact too when one is supplied by CI.
        if CommandLine.arguments.count > 2, !CommandLine.arguments[2].isEmpty {
            let descriptor = URL(fileURLWithPath: CommandLine.arguments[2])
            let actual = try JSONDecoder().decode(AgentRuntimeManifest.self, from: Data(contentsOf: descriptor))
            try actual.validate()
            let downloaded = descriptor.deletingLastPathComponent().appendingPathComponent(actual.url.lastPathComponent)
            try expect(try AgentRuntimeArchive.digest(of: downloaded) == actual.sha256, "packaged archive hash mismatch")
            let actualDirectory = root.appendingPathComponent("actual")
            try AgentRuntimeArchive.extract(downloaded, to: actualDirectory, manifest: actual)
            let candidate = AgentRuntimeInstallation(directory: actualDirectory, manifest: actual)
            try AgentRuntimeArchive.verify(candidate)
            try await AgentRuntimeHealth.probe(candidate)
            checks += 1
        }
        print("Agent runtime: \(checks) checks passed")
    }
}
