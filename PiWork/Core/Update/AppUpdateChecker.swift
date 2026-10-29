import AppKit
import Combine
import Foundation

struct ReleaseVersion: Comparable {
    private let components: [Int]

    init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }

        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let component = Int(part) else {
                return nil
            }
            components.append(component)
        }

        while components.count > 1 && components.last == 0 {
            components.removeLast()
        }
        self.components = components
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

enum AppArchitecture: String {
    case arm64
    case x86_64

    static var current: AppArchitecture {
#if arch(arm64)
        return .arm64
#elseif arch(x86_64)
        return .x86_64
#else
#error("PiWork updates support only arm64 and x86_64 macOS builds")
#endif
    }
}

struct AppUpdate: Equatable {
    let version: String
    let downloadURL: URL
}

enum AppUpdateCheckResult: Equatable {
    case upToDate(latestVersion: String)
    case updateAvailable(AppUpdate)
}

enum AppUpdateCheckError: LocalizedError, Equatable {
    case invalidResponse
    case server(statusCode: Int)
    case rateLimited
    case compatibleAssetNotFound
    case cannotOpenDownload

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return L10n.string("update.error.response")
        case let .server(statusCode): return L10n.format("update.error.server", statusCode)
        case .rateLimited: return L10n.string("update.error.rate_limited")
        case .compatibleAssetNotFound: return L10n.string("update.error.asset")
        case .cannotOpenDownload: return L10n.string("update.error.open")
        }
    }
}

struct GitHubReleaseUpdateChecker {
    private static let repository = "section9-lab/pi-work"
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!
    private static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    static let publicReleaseURL = repositoryURL.appendingPathComponent("releases/latest")

    let currentVersion: String
    let architecture: AppArchitecture
    let session: URLSession
    let releaseURL: URL
    let fallbackURL: URL?

    init(
        currentVersion: String,
        architecture: AppArchitecture = .current,
        session: URLSession = .shared,
        releaseURL: URL = GitHubReleaseUpdateChecker.latestReleaseURL,
        fallbackURL: URL? = GitHubReleaseUpdateChecker.publicReleaseURL
    ) {
        self.currentVersion = currentVersion
        self.architecture = architecture
        self.session = session
        self.releaseURL = releaseURL
        self.fallbackURL = fallbackURL
    }

    func check() async throws -> AppUpdateCheckResult {
        guard ReleaseVersion(currentVersion) != nil else { throw AppUpdateCheckError.invalidResponse }
        do {
            return try await checkAPI()
        } catch {
            try Task.checkCancellation()
            guard let fallbackURL,
                  !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled,
                  (error as? AppUpdateCheckError) != .compatibleAssetNotFound else { throw error }
            let apiError = error
            do {
                return try await checkPublicRelease(at: fallbackURL)
            } catch {
                try Task.checkCancellation()
                if (error as? AppUpdateCheckError) == .compatibleAssetNotFound { throw error }
                throw apiError
            }
        }
    }

    private func checkAPI() async throws -> AppUpdateCheckResult {
        var request = URLRequest(
            url: releaseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdateCheckError.invalidResponse
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 429 || (response.statusCode == 403
                && response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
                throw AppUpdateCheckError.rateLimited
            }
            throw AppUpdateCheckError.server(statusCode: response.statusCode)
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw AppUpdateCheckError.invalidResponse
        }

        guard let installedVersion = ReleaseVersion(currentVersion),
              let latestVersion = ReleaseVersion(release.tagName) else {
            throw AppUpdateCheckError.invalidResponse
        }

        let version = normalizedVersion(release.tagName)
        guard installedVersion < latestVersion else {
            return .upToDate(latestVersion: version)
        }

        let assetSuffix = "-macos-\(architecture.rawValue).dmg"
        guard let asset = release.assets.first(where: {
            $0.name.lowercased().hasSuffix(assetSuffix.lowercased())
                && isTrustedGitHubURL($0.browserDownloadURL)
        }) else {
            throw AppUpdateCheckError.compatibleAssetNotFound
        }

        return .updateAvailable(AppUpdate(
            version: version,
            downloadURL: asset.browserDownloadURL
        ))
    }

    /// The public latest-release redirect does not consume anonymous API quota.
    /// HEAD requests discover the tag and verify the DMG without downloading it.
    private func checkPublicRelease(at url: URL) async throws -> AppUpdateCheckResult {
        let response = try await head(url)
        guard response.statusCode == 200, let resolvedURL = response.url,
              isTrustedGitHubURL(resolvedURL),
              resolvedURL.user == nil, resolvedURL.password == nil, resolvedURL.port == nil,
              resolvedURL.query == nil, resolvedURL.fragment == nil else {
            throw AppUpdateCheckError.invalidResponse
        }
        let components = resolvedURL.pathComponents
        let tagPrefix = Self.repositoryURL.pathComponents + ["releases", "tag"]
        guard components.count == tagPrefix.count + 1, components.starts(with: tagPrefix),
              let tag = components.last, tag.utf8.count <= 64,
              tag == tag.trimmingCharacters(in: .whitespacesAndNewlines),
              let latest = ReleaseVersion(tag), let installed = ReleaseVersion(currentVersion) else {
            throw AppUpdateCheckError.invalidResponse
        }
        let version = normalizedVersion(tag)
        guard installed < latest else { return .upToDate(latestVersion: version) }

        let downloadURL = Self.repositoryURL.appendingPathComponent("releases/download")
            .appendingPathComponent(tag)
            .appendingPathComponent("PiWork-\(version)-macos-\(architecture.rawValue).dmg")
        let assetResponse = try await head(downloadURL)
        if assetResponse.statusCode == 404 { throw AppUpdateCheckError.compatibleAssetNotFound }
        guard assetResponse.statusCode == 200, let assetURL = assetResponse.url,
              AgentRuntimeDownload.isTrusted(assetURL),
              assetURL.host?.lowercased() != "github.com" || assetURL == downloadURL else {
            throw AppUpdateCheckError.invalidResponse
        }
        return .updateAvailable(AppUpdate(version: version, downloadURL: downloadURL))
    }

    private func head(_ url: URL) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw AppUpdateCheckError.invalidResponse }
        return response
    }

    private func normalizedVersion(_ tag: String) -> String {
        guard tag.first == "v" || tag.first == "V" else { return tag }
        return String(tag.dropFirst())
    }

    private func isTrustedGitHubURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate(latestVersion: String)
    case updateAvailable(AppUpdate)
    case failed
}

@MainActor
final class AppUpdateController: ObservableObject {
    typealias Check = () async throws -> AppUpdateCheckResult

    @Published private(set) var state = AppUpdateState.idle

    let currentVersion: String
    private let check: Check
    private let openURL: (URL) -> Bool
    private var lastError: Error?

    init(
        currentVersion: String,
        check: @escaping Check,
        openURL: @escaping (URL) -> Bool
    ) {
        self.currentVersion = currentVersion
        self.check = check
        self.openURL = openURL
    }

    convenience init(
        bundle: Bundle = .main,
        architecture: AppArchitecture = .current,
        session: URLSession = .shared
    ) {
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
        let checker = GitHubReleaseUpdateChecker(
            currentVersion: version,
            architecture: architecture,
            session: session
        )
        self.init(
            currentVersion: version,
            check: { try await checker.check() },
            openURL: { NSWorkspace.shared.open($0) }
        )
    }

    var isChecking: Bool { state == .checking }

    var failureDescription: String {
        lastError?.localizedDescription ?? L10n.string("update.alert.failed.message")
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        lastError = nil
        state = .checking
        do {
            switch try await check() {
            case let .upToDate(latestVersion):
                state = .upToDate(latestVersion: latestVersion)
            case let .updateAvailable(update):
                state = .updateAvailable(update)
            }
        } catch {
            lastError = error
            state = .failed
        }
    }

    func checkForUpdatesAndPresent() async {
        await checkForUpdates()
        presentResult()
    }

    @discardableResult
    func openAvailableUpdate() -> Bool {
        guard case let .updateAvailable(update) = state else { return false }
        let opened = openURL(update.downloadURL)
        if !opened {
            lastError = AppUpdateCheckError.cannotOpenDownload
            state = .failed
        }
        return opened
    }

    private func presentResult() {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch state {
        case let .upToDate(latestVersion):
            alert.messageText = L10n.string("update.alert.up_to_date.title")
            alert.informativeText = L10n.format(
                "update.alert.up_to_date.message",
                latestVersion
            )
            alert.addButton(withTitle: L10n.string("common.done"))
        case let .updateAvailable(update):
            alert.messageText = L10n.string("update.alert.available.title")
            alert.informativeText = L10n.format(
                "update.alert.available.message",
                update.version,
                currentVersion
            )
            alert.addButton(withTitle: L10n.string("update.download"))
            alert.addButton(withTitle: L10n.string("update.later"))
        case .failed:
            alert.alertStyle = .warning
            alert.messageText = L10n.string("update.alert.failed.title")
            alert.informativeText = failureDescription
            alert.addButton(withTitle: L10n.string("common.done"))
        case .idle, .checking:
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if case .updateAvailable = state,
           response == .alertFirstButtonReturn,
           !openAvailableUpdate() {
            presentResult()
        }
    }
}
