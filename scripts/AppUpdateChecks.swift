import AppKit
import Sparkle
import SwiftUI

@main
@MainActor
enum AppUpdateChecks {
    static func main() throws {
        _ = NSApplication.shared
        var count = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "AppUpdateChecks", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: message]) }
            count += 1
        }
        let controller = AppUpdateController()
        var choices: [SPUUserUpdateChoice] = []
        controller.offerUpdate(version: "1.0.1") { choices.append($0) }
        try expect(choices.isEmpty, "Discovery downloaded without consent")
        controller.installAvailableUpdate()
        controller.installAvailableUpdate()
        try expect(choices == [.install], "Upgrade consent was delivered more than once")
        var cancelled = false
        controller.showDownloadInitiated { cancelled = true }
        controller.showDownloadDidReceiveData(ofLength: 50)
        try expect(controller.state == .downloading(progress: nil), "Unknown content length was misrepresented")
        controller.showDownloadDidReceiveExpectedContentLength(100)
        try expect(controller.state == .downloading(progress: 0.5), "Download progress did not advance")
        controller.showDownloadDidReceiveExpectedContentLength(25)
        try expect(controller.state == .downloading(progress: 1), "Progress exceeded its bounds")
        controller.cancel()
        try expect(cancelled && controller.state == .idle, "Cancel did not stop the download")
        controller.showReady(toInstallAndRelaunch: { choices.append($0) })
        try expect(choices == [.install, .skip], "Cancelled download continued to install")
        controller.offerUpdate(version: "1.0.1") { _ in }
        controller.installAvailableUpdate()
        controller.showReady(toInstallAndRelaunch: { choices.append($0) })
        try expect(choices.last == .install, "One-click update asked for a second consent")
        controller.dismissUpdateInstallation()
        let error = NSError(domain: "Checks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid signature"])
        controller.showUpdaterError(error) {}
        controller.dismissUpdateInstallation()
        try expect(controller.state == .failed && controller.failureDescription == "Invalid signature",
                   "Installation error was hidden")
        let latest = NSError(domain: "Checks", code: 2, userInfo: [
            SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)])
        controller.showUpdateNotFoundWithError(latest) {}
        try expect(controller.state == .upToDate, "Current version was not recognized")
        try expect(AppUpdateController.feedURL(architecture: .arm64) != AppUpdateController.feedURL(architecture: .x86_64),
                   "Architecture feeds collide")
        let intel = AppUpdateController(architecture: .x86_64)
        try expect(intel.responds(to: NSSelectorFromString("feedURLStringForUpdater:")),
                   "Sparkle cannot call the architecture feed delegate")
        let previousLanguage = LanguageStore.shared.language
        defer { LanguageStore.shared.language = previousLanguage }
        for language in AppLanguage.allCases {
            LanguageStore.shared.language = language
            controller.offerUpdate(version: "1.0.1") { _ in }
            for scheme in [ColorScheme.light, .dark] {
                for width: CGFloat in [436, 620, 900] {
                    let host = NSHostingController(rootView: AppUpdateBanner(controller: controller)
                        .environment(\.colorScheme, scheme))
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 400))
                    try expect(size.width <= width, "Update banner overflows in \(language.rawValue) at \(width)")
                    if language == .simplifiedChinese && width == 620 {
                        host.view.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
                        host.view.layoutSubtreeIfNeeded()
                        if let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                            let suffix = scheme == .dark ? "dark" : "light"
                            try bitmap.representation(using: .png, properties: [:])?.write(
                                to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("app-update-banner-\(suffix).png"))
                        }
                    }
                }
            }
        }
        print("App update checks: \(count) passed (consent, cancellation, progress, errors, six languages, narrow/light/dark layouts)")
    }
}
