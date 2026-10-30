import AppKit
import Combine
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
        let background = AppUpdateController()
        let networkError = NSError(domain: "Checks", code: 0,
                                   userInfo: [NSLocalizedDescriptionKey: "Offline"])
        background.showUpdaterError(networkError) {}
        try expect(background.isFailureSilent, "Background check failure interrupted the sidebar")
        background.offerUpdate(version: "1.0.1") { _ in }
        try expect(background.state == .available(version: "1.0.1"), "Discovery did not recover from a background error")
        background.installAvailableUpdate()
        background.showUpdaterError(networkError) {}
        try expect(!background.isFailureSilent, "Explicit installation failure was hidden")
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
        let activity = CurrentValueSubject<Bool, Never>(true)
        controller.observeTaskActivity(activity.eraseToAnyPublisher(), current: { activity.value })
        choices = []
        controller.offerUpdate(version: "1.0.1") { choices.append($0) }
        controller.installAvailableUpdate()
        try expect(choices.isEmpty && controller.state == .available(version: "1.0.1"),
                   "Busy click started a download")
        try expect(controller.installationHelp == L10n.string("update.tasks_running"), "Busy tooltip is missing")
        activity.send(false)
        try expect(choices.isEmpty && !controller.hasActiveTasks, "Task completion queued an upgrade")
        controller.installAvailableUpdate()
        try expect(choices == [.install], "A fresh idle click did not begin downloading")
        activity.send(true)
        controller.showReady(toInstallAndRelaunch: { choices.append($0) })
        controller.installPreparedUpdate()
        try expect(choices == [.install] && controller.state == .readyToInstall,
                   "A task started during downloading was interrupted")
        activity.send(false)
        try expect(choices == [.install], "Task completion silently restarted the app")
        controller.installPreparedUpdate()
        controller.installPreparedUpdate()
        try expect(choices == [.install, .install], "Restart consent was lost or delivered twice")
        var liveActivity = true
        controller.observeTaskActivity(Just(false).eraseToAnyPublisher(), current: { liveActivity })
        choices = []
        controller.offerUpdate(version: "1.0.1") { choices.append($0) }
        controller.installAvailableUpdate()
        try expect(choices.isEmpty, "An outdated UI publisher bypassed the live download guard")
        var relaunches = 0
        try expect(controller.postponeRelaunchIfNeeded { relaunches += 1 }, "Late task did not postpone relaunch")
        controller.installPreparedUpdate()
        try expect(relaunches == 0, "Busy restart invoked the postponed handler")
        liveActivity = false
        try expect(relaunches == 0, "Postponed handler ran without another click")
        controller.installPreparedUpdate()
        controller.installPreparedUpdate()
        try expect(relaunches == 1, "Postponed relaunch did not run exactly once")
        try expect(controller.responds(to: NSSelectorFromString("updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:")),
                   "Sparkle cannot call the relaunch guard")
        liveActivity = true
        controller.offerUpdate(version: "1.0.1", stage: .installing) { choices.append($0) }
        try expect(controller.state == .readyToInstall, "A restored prepared update did not expose Restart")
        controller.installPreparedUpdate()
        try expect(choices.isEmpty, "Restored update interrupted a task")
        controller.dismissUpdateInstallation()
        liveActivity = false
        controller.installPreparedUpdate()
        try expect(choices.isEmpty, "Dismissed prepared handler could still restart")
        liveActivity = true
        controller.showInstallingUpdate(withApplicationTerminated: false) { relaunches += 1 }
        controller.retryInstallationRelaunch()
        try expect(relaunches == 1, "Busy retry interrupted a task")
        liveActivity = false
        controller.retryInstallationRelaunch()
        try expect(relaunches == 2, "Idle explicit retry did not relaunch")
        controller.dismissUpdateInstallation()
        let previousLanguage = LanguageStore.shared.language
        defer { LanguageStore.shared.language = previousLanguage }
        for language in AppLanguage.allCases {
            LanguageStore.shared.language = language
            for scheme in [ColorScheme.light, .dark] {
                for width: CGFloat in [220, 260, 420] {
                    for phase in ["available", "busy", "ready", "downloading", "preparing", "failed", "current"] {
                        liveActivity = phase == "busy"
                        controller.observeTaskActivity(Just(liveActivity).eraseToAnyPublisher(), current: { liveActivity })
                        switch phase {
                        case "ready": controller.offerUpdate(version: "1.0.1", stage: .installing) { _ in }
                        case "downloading":
                            controller.showDownloadInitiated {}
                            controller.showDownloadDidReceiveExpectedContentLength(100)
                            controller.showDownloadDidReceiveData(ofLength: 37)
                        case "preparing": controller.showDownloadDidStartExtractingUpdate()
                        case "failed": controller.showUpdaterError(error) {}
                        case "current": controller.showUpdateNotFoundWithError(latest) {}
                        default: controller.offerUpdate(version: "1.0.1") { _ in }
                        }
                        let host = NSHostingController(rootView: AppUpdateAccountRow(controller: controller) {
                            HStack(spacing: 10) {
                                Text("J").frame(width: 30, height: 30).background(Circle().fill(AppPalette.raisedSurface))
                                Text("JackWang").font(.system(size: 14)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                        .padding(.horizontal, 15).padding(.vertical, 18)
                        .background(AppPalette.sidebarSurface)
                        .environment(\.colorScheme, scheme))
                        let size = host.sizeThatFits(in: CGSize(width: width, height: 400))
                        try expect(size.width <= width, "Account update row overflows in \(language.rawValue)/\(phase) at \(width)")
                        try expect(size.height <= 130, "Account and separate update row are too tall")
                        if language == .simplifiedChinese && width == 260 {
                            host.view.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
                            host.view.layoutSubtreeIfNeeded()
                            if let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                                let suffix = scheme == .dark ? "dark" : "light"
                                try bitmap.representation(using: .png, properties: [:])?.write(
                                    to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("app-update-sidebar-\(phase)-\(suffix).png"))
                            }
                        }
                    }
                }
            }
        }
        print("App update checks: \(count) passed (busy guards, explicit restart, consent, progress, errors, six languages, sidebar/light/dark layouts)")
    }
}
