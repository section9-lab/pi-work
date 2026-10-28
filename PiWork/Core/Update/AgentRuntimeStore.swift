import Foundation

struct AgentRuntimeInstallation: Equatable {
    let directory: URL
    let manifest: AgentRuntimeManifest
    var executableURL: URL { directory.appendingPathComponent(AgentHostExecutable.filename) }
    var bunURL: URL { directory.appendingPathComponent(AgentHostExecutable.bunFilename) }
}

struct AgentRuntimeSelection: Codable, Equatable {
    var active: String?
    var previous: String?
    var pending: String?
    var trial: String?
    var lastFailure: String?
}

/// The selection is a small atomic journal. Version directories are immutable.
actor AgentRuntimeStore {
    let root: URL
    let appVersion: String
    private let fileManager = FileManager.default
    private var didBeginLaunch = false

    init(root: URL, appVersion: String) {
        self.root = root
        self.appVersion = appVersion
    }

    static func applicationDefault() -> AgentRuntimeStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AgentRuntimeStore(
            root: support.appendingPathComponent("pi-work/Runtimes", isDirectory: true),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        )
    }

    func selection() throws -> AgentRuntimeSelection {
        let url = root.appendingPathComponent("selection.json")
        guard fileManager.fileExists(atPath: url.path) else { return AgentRuntimeSelection() }
        return try JSONDecoder().decode(AgentRuntimeSelection.self, from: Data(contentsOf: url))
    }

    func installation(_ id: String) throws -> AgentRuntimeInstallation {
        guard AgentRuntimeManifest.isSafePath(id), !id.contains("/") else {
            throw AgentRuntimeError.invalidManifest
        }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let manifest = try JSONDecoder().decode(
            AgentRuntimeManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("installed.json"))
        )
        try manifest.validate()
        guard manifest.id == id, manifest.isCompatible(appVersion: appVersion) else {
            throw AgentRuntimeError.incompatible
        }
        return AgentRuntimeInstallation(directory: directory, manifest: manifest)
    }

    func beginLaunch() throws -> AgentRuntimeInstallation? {
        var state: AgentRuntimeSelection
        do { state = try selection() } catch {
            // A damaged journal must never prevent the bundled runtime from starting.
            state = AgentRuntimeSelection(lastFailure: AgentRuntimeError.invalidManifest.localizedDescription)
        }
        if !didBeginLaunch {
            if state.trial != nil {
                state.active = state.previous
                state.previous = nil
                state.trial = nil
                state.lastFailure = AgentRuntimeError.healthCheck.localizedDescription
            }
            if let pending = state.pending {
                state.previous = state.active
                state.active = pending == "bundled" ? nil : pending
                state.trial = state.active
                state.pending = nil
            }
            try save(state)
            didBeginLaunch = true
        }
        return try resolveActive(state)
    }

    func stage(_ installation: AgentRuntimeInstallation) throws {
        var state = try selection()
        guard state.active != installation.manifest.id else { return }
        state.pending = installation.manifest.id
        state.lastFailure = nil
        try save(state)
    }

    func confirm(_ id: String) throws {
        var state = try selection()
        guard state.active == id else { return }
        state.trial = nil
        try save(state)
    }

    func reject(_ id: String, reason: String) throws -> AgentRuntimeInstallation? {
        var state = try selection()
        guard state.active == id else { return try resolveActive(state) }
        state.active = state.previous
        state.previous = nil
        state.trial = nil
        if state.pending == id { state.pending = nil }
        state.lastFailure = reason
        try save(state)
        return try resolveActive(state)
    }

    func cancelPending() throws {
        var state = try selection()
        state.pending = nil
        try save(state)
    }

    /// Manual rollback is also staged, so an in-flight conversation is untouched.
    func stageRollback() throws {
        var state = try selection()
        guard state.active != nil else { return }
        state.pending = state.previous ?? "bundled"
        try save(state)
    }

    private func resolveActive(_ state: AgentRuntimeSelection) throws -> AgentRuntimeInstallation? {
        guard let active = state.active, active != "bundled" else { return nil }
        do { return try installation(active) } catch {
            return try reject(active, reason: error.localizedDescription)
        }
    }

    private func save(_ state: AgentRuntimeSelection) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("selection.json"), options: .atomic)
    }
}
