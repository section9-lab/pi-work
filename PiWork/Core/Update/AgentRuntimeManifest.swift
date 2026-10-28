import Foundation

/// A PiWork adapter release, rather than an arbitrary upstream Pi installation.
struct AgentRuntimeManifest: Codable, Equatable {
    let schemaVersion: Int
    let version: String
    let piVersion: String
    let apiVersion: Int
    let acpVersion: Int
    let minimumAppVersion: String
    let maximumAppVersion: String?
    let minimumMacOSVersion: String
    let architecture: String
    let url: URL
    let byteCount: Int64
    let sha256: String
    let files: [String: String]

    var id: String { "\(version)-\(architecture)" }
    static let maximumArchiveBytes: Int64 = 256 * 1024 * 1024
    static let maximumExpandedBytes = 768 * 1024 * 1024
    static let repository = "https://github.com/section9-lab/pi-work/releases/download/"
    static let indexURL = URL(string: repository + "agent-runtime-stable/runtime-index.json")!

    func validate() throws {
        guard schemaVersion == 1,
              Self.isVersion(version), Self.isVersion(piVersion),
              Self.isVersion(minimumAppVersion), Self.isVersion(minimumMacOSVersion),
              maximumAppVersion.map(Self.isVersion) ?? true,
              ["arm64", "x86_64"].contains(architecture),
              byteCount > 0, byteCount <= Self.maximumArchiveBytes,
              Self.isDigest(sha256), !files.isEmpty, files.count <= 4096,
              files[AgentHostExecutable.filename] != nil,
              files[AgentHostExecutable.bunFilename] != nil,
              files.keys.contains(where: { $0.hasPrefix("export-html/") }),
              files.keys.contains(where: { $0.hasPrefix("theme/") }),
              files.allSatisfy({ Self.isPayloadPath($0.key) && Self.isDigest($0.value) }),
              url.absoluteString == Self.repository
                + "runtime-v\(version)/PiWorkRuntime-\(version)-macos-\(architecture).tar.gz"
        else { throw AgentRuntimeError.invalidManifest }
        if let maximumAppVersion,
           let minimum = ReleaseVersion(minimumAppVersion),
           let maximum = ReleaseVersion(maximumAppVersion), minimum > maximum {
            throw AgentRuntimeError.invalidManifest
        }
    }

    func isCompatible(
        appVersion: String,
        architecture: AppArchitecture = .current,
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionStringForRuntime
    ) -> Bool {
        guard apiVersion == 1, acpVersion == 1,
              self.architecture == architecture.rawValue,
              let app = ReleaseVersion(appVersion),
              let minimumApp = ReleaseVersion(minimumAppVersion), app >= minimumApp,
              let os = ReleaseVersion(macOSVersion),
              let minimumOS = ReleaseVersion(minimumMacOSVersion), os >= minimumOS
        else { return false }
        if let maximumAppVersion, let maximum = ReleaseVersion(maximumAppVersion), app > maximum {
            return false
        }
        return true
    }

    static func isVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
            && ReleaseVersion(value) != nil
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 255
            && !path.contains("\\") && !path.utf8.contains(where: { $0 < 32 || $0 == 127 })
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isPayloadPath(_ path: String) -> Bool {
        isSafePath(path) && (path == AgentHostExecutable.filename
            || path == AgentHostExecutable.bunFilename
            || path.hasPrefix("export-html/") || path.hasPrefix("theme/"))
    }
}

struct AgentRuntimeIndex: Codable {
    let schemaVersion: Int
    let releases: [AgentRuntimeManifest]

    func latestCompatible(appVersion: String, architecture: AppArchitecture = .current) throws
        -> AgentRuntimeManifest? {
        guard schemaVersion == 1, releases.count <= 128 else {
            throw AgentRuntimeError.invalidManifest
        }
        for release in releases { try release.validate() }
        return releases.filter { $0.isCompatible(appVersion: appVersion, architecture: architecture) }
            .max { ReleaseVersion($0.version)! < ReleaseVersion($1.version)! }
    }
}

enum AgentRuntimeError: LocalizedError {
    case invalidManifest, incompatible, integrity, invalidArchive, healthCheck, unavailable, busy

    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidManifest: key = "runtime.error.manifest"
        case .incompatible: key = "runtime.error.compatibility"
        case .integrity: key = "runtime.error.integrity"
        case .invalidArchive: key = "runtime.error.archive"
        case .healthCheck: key = "runtime.error.health"
        case .unavailable: key = "runtime.error.unavailable"
        case .busy: key = "runtime.error.busy"
        }
        return L10n.string(key)
    }
}

private extension ProcessInfo {
    var operatingSystemVersionStringForRuntime: String {
        let version = operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
