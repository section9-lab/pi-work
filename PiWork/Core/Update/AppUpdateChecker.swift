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

enum AppUpdateCheckError: Error, Equatable {
    case invalidResponse
    case server(statusCode: Int)
    case compatibleAssetNotFound
}

struct GitHubReleaseUpdateChecker {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/section9-lab/pi-work/releases/latest"
    )!

    let currentVersion: String
    let architecture: AppArchitecture
    let session: URLSession
    let releaseURL: URL

    init(
        currentVersion: String,
        architecture: AppArchitecture = .current,
        session: URLSession = .shared,
        releaseURL: URL = GitHubReleaseUpdateChecker.latestReleaseURL
    ) {
        self.currentVersion = currentVersion
        self.architecture = architecture
        self.session = session
        self.releaseURL = releaseURL
    }

    func check() async throws -> AppUpdateCheckResult {
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

    func checkForUpdates() async {
        guard !isChecking else { return }
        state = .checking
        do {
            switch try await check() {
            case let .upToDate(latestVersion):
                state = .upToDate(latestVersion: latestVersion)
            case let .updateAvailable(update):
                state = .updateAvailable(update)
            }
        } catch {
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
        if !opened { state = .failed }
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
            alert.informativeText = L10n.string("update.alert.failed.message")
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
