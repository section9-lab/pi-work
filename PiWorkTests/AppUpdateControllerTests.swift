import XCTest
import Combine
import Sparkle
import SwiftUI
@testable import PiWork

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testDiscoveryDoesNotDownloadUntilTheUserInstallsAndOnlyRepliesOnce() {
        let controller = AppUpdateController()
        var choices: [SPUUserUpdateChoice] = []
        controller.offerUpdate(version: "0.2.0") { choices.append($0) }
        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(controller.state, .available(version: "0.2.0"))
        controller.installAvailableUpdate()
        controller.installAvailableUpdate()
        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(controller.state, .downloading(progress: nil))
    }

    func testLaterDismissesTheOfferAndDoesNotAuthorizeAnInstallation() {
        let controller = AppUpdateController()
        var choices: [SPUUserUpdateChoice] = []
        controller.offerUpdate(version: "0.2.0") { choices.append($0) }
        controller.dismissOffer()
        controller.installAvailableUpdate()
        controller.showReady(toInstallAndRelaunch: { choices.append($0) })
        XCTAssertEqual(choices, [.dismiss, .skip])
    }

    func testDownloadCanBeCancelledAndNoLongerInstallsAfterPreparation() {
        let controller = AppUpdateController()
        controller.offerUpdate(version: "0.2.0") { _ in }
        controller.installAvailableUpdate()
        var cancelled = 0
        controller.showDownloadInitiated { cancelled += 1 }
        controller.cancel()
        controller.cancel()
        var reply: SPUUserUpdateChoice?
        controller.showReady(toInstallAndRelaunch: { reply = $0 })
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(reply, .skip)
    }

    func testDownloadProgressHandlesUnknownAndChangingContentLengths() {
        let controller = AppUpdateController()
        controller.showDownloadInitiated {}
        controller.showDownloadDidReceiveData(ofLength: 50)
        XCTAssertEqual(controller.state, .downloading(progress: nil))
        controller.showDownloadDidReceiveExpectedContentLength(100)
        XCTAssertEqual(controller.state, .downloading(progress: 0.5))
        controller.showDownloadDidReceiveExpectedContentLength(25)
        XCTAssertEqual(controller.state, .downloading(progress: 1))
        controller.showDownloadDidReceiveExpectedContentLength(0)
        XCTAssertEqual(controller.state, .downloading(progress: nil))
    }

    func testExtractionDisablesCancellationAndClampsInvalidProgress() {
        let controller = AppUpdateController()
        var cancelled = false
        controller.showDownloadInitiated { cancelled = true }
        controller.showDownloadDidStartExtractingUpdate()
        controller.cancel()
        XCTAssertFalse(cancelled)
        XCTAssertFalse(controller.canCancel)
        controller.showExtractionReceivedProgress(.nan)
        XCTAssertEqual(controller.state, .extracting(progress: nil))
        controller.showExtractionReceivedProgress(2)
        XCTAssertEqual(controller.state, .extracting(progress: 1))
    }

    func testRelaunchAutomaticallyContinuesWithoutSecondConsent() {
        let controller = AppUpdateController()
        var events: [String] = []
        controller.offerUpdate(version: "0.2.0") { _ in events.append("download") }
        controller.installAvailableUpdate()
        controller.showReady(toInstallAndRelaunch: { choice in
            XCTAssertEqual(choice, .install)
            events.append("install")
        })
        XCTAssertEqual(events, ["download", "install"])
    }

    func testFailureIsRetainedAfterSparkleDismissesAndNewOfferCanRetry() {
        let controller = AppUpdateController()
        let error = NSError(domain: "UpdateTests", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Signature verification failed"])
        var acknowledged = false
        controller.showUpdaterError(error) { acknowledged = true }
        controller.dismissUpdateInstallation()
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.failureDescription, error.localizedDescription)
        controller.offerUpdate(version: "0.2.0") { _ in }
        XCTAssertEqual(controller.state, .available(version: "0.2.0"))
    }

    func testArchitecturesHaveIndependentUpdateFeeds() {
        XCTAssertEqual(AppUpdateController.feedURL(architecture: .arm64).lastPathComponent, "appcast-arm64.xml")
        XCTAssertEqual(AppUpdateController.feedURL(architecture: .x86_64).lastPathComponent, "appcast-x86_64.xml")
    }

    func testRunningTaskBlocksDownloadWithoutQueuingIt() {
        let controller = AppUpdateController()
        let activity = CurrentValueSubject<Bool, Never>(true)
        controller.observeTaskActivity(activity.eraseToAnyPublisher(), current: { activity.value })
        var choices: [SPUUserUpdateChoice] = []
        controller.offerUpdate(version: "0.2.0") { choices.append($0) }
        controller.installAvailableUpdate()
        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(controller.state, .available(version: "0.2.0"))
        activity.send(false)
        XCTAssertTrue(choices.isEmpty, "Finishing a task must not start an update")
        controller.installAvailableUpdate()
        XCTAssertEqual(choices, [.install])
    }

    func testAllActiveSessionPhasesBlockUpdatesIncludingApprovalWaitAndStopping() {
        for phase in [SessionRecordRunState.opening, .submitting, .running, .stopping] {
            XCTAssertTrue(phase.preventsAppUpdate)
        }
        for phase in [SessionRecordRunState.idle, .failed] {
            XCTAssertFalse(phase.preventsAppUpdate)
        }
    }

    func testTaskStartedDuringDownloadRequiresExplicitRestartAfterItFinishes() {
        let controller = AppUpdateController()
        let activity = CurrentValueSubject<Bool, Never>(false)
        controller.observeTaskActivity(activity.eraseToAnyPublisher(), current: { activity.value })
        controller.offerUpdate(version: "0.2.0") { _ in }
        controller.installAvailableUpdate()
        activity.send(true)
        var choices: [SPUUserUpdateChoice] = []
        controller.showReady(toInstallAndRelaunch: { choices.append($0) })
        XCTAssertEqual(controller.state, .readyToInstall)
        controller.installPreparedUpdate()
        XCTAssertTrue(choices.isEmpty)
        activity.send(false)
        XCTAssertTrue(choices.isEmpty)
        controller.installPreparedUpdate()
        controller.installPreparedUpdate()
        XCTAssertEqual(choices, [.install])
    }

    func testRelaunchDelegateRechecksLiveActivityAndNeverSchedulesAnAutomaticRestart() {
        let controller = AppUpdateController()
        var active = false
        controller.observeTaskActivity(Just(false).eraseToAnyPublisher(), current: { active })
        active = true // The source changed before its UI publisher delivered.
        var relaunches = 0
        XCTAssertTrue(controller.postponeRelaunchIfNeeded { relaunches += 1 })
        controller.installPreparedUpdate()
        XCTAssertEqual(relaunches, 0)
        active = false
        XCTAssertEqual(relaunches, 0)
        controller.installPreparedUpdate()
        controller.installPreparedUpdate()
        XCTAssertEqual(relaunches, 1)
        XCTAssertTrue(controller.responds(to: NSSelectorFromString(
            "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:")))
    }

    func testRestoredPreparedUpdateShowsRestartAndRespectsRunningTasks() {
        let controller = AppUpdateController()
        let activity = CurrentValueSubject<Bool, Never>(true)
        controller.observeTaskActivity(activity.eraseToAnyPublisher(), current: { activity.value })
        var choices: [SPUUserUpdateChoice] = []
        controller.offerUpdate(version: "0.2.0", stage: .installing) { choices.append($0) }
        XCTAssertEqual(controller.state, .readyToInstall)
        controller.installPreparedUpdate()
        XCTAssertTrue(choices.isEmpty)
        activity.send(false)
        controller.installPreparedUpdate()
        XCTAssertEqual(choices, [.install])
    }

    func testRetryRelaunchIsBlockedAndDismissalDropsThePreparedCallback() {
        let controller = AppUpdateController()
        let activity = CurrentValueSubject<Bool, Never>(true)
        controller.observeTaskActivity(activity.eraseToAnyPublisher(), current: { activity.value })
        var relaunches = 0
        controller.showInstallingUpdate(withApplicationTerminated: false) { relaunches += 1 }
        controller.retryInstallationRelaunch()
        XCTAssertEqual(relaunches, 0)
        activity.send(false)
        controller.retryInstallationRelaunch()
        XCTAssertEqual(relaunches, 1)
        activity.send(true)
        XCTAssertTrue(controller.postponeRelaunchIfNeeded { relaunches += 1 })
        controller.dismissUpdateInstallation()
        activity.send(false)
        controller.installPreparedUpdate()
        XCTAssertEqual(relaunches, 1)
    }

    func testSidebarUpdateFitsTheNarrowestSidebarInBothAppearances() throws {
        let controller = AppUpdateController()
        controller.offerUpdate(version: "0.2.0") { _ in }
        for width: CGFloat in [190, 230, 390] {
            for scheme in [ColorScheme.light, .dark] {
                let view = NSHostingController(rootView: AppUpdateSidebarAccessory(controller: controller)
                    .environment(\.colorScheme, scheme))
                XCTAssertLessThanOrEqual(view.sizeThatFits(in: CGSize(width: width, height: 400)).width, width)
            }
        }
    }

    // MARK: - Check cadence

    private func shanghaiSchedule() -> AppUpdateCheckSchedule {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return AppUpdateCheckSchedule(calendar: calendar)
    }

    private func time(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 16, hour: hour, minute: minute))!
    }

    func testWorkingHoursRunEveryTenMinutes() {
        let schedule = shanghaiSchedule()
        XCTAssertTrue(schedule.isWithinWorkingHours(time(9, 0)))
        XCTAssertTrue(schedule.isWithinWorkingHours(time(18, 59)))
        XCTAssertEqual(schedule.delay(after: time(10, 0)), 600, accuracy: 1)
        XCTAssertEqual(schedule.delay(after: time(14, 37)), 600, accuracy: 1)
    }

    func testOutsideWorkingHoursStayHourly() {
        let schedule = shanghaiSchedule()
        XCTAssertFalse(schedule.isWithinWorkingHours(time(8, 30)))
        XCTAssertFalse(schedule.isWithinWorkingHours(time(19, 0)))
        XCTAssertFalse(schedule.isWithinWorkingHours(time(23, 15)))
        // 30 minutes before the window opens: the boundary shortens the idle
        // hour so the frequent cadence starts at 09:00 sharp.
        XCTAssertEqual(schedule.delay(after: time(8, 30)), 1800, accuracy: 1)
        XCTAssertEqual(schedule.delay(after: time(22, 0)), 3600, accuracy: 1)
        XCTAssertEqual(schedule.delay(after: time(3, 0)), 3600, accuracy: 1)
    }

    func testWorkingHourBoundariesShortenTheLastDelay() {
        let schedule = shanghaiSchedule()
        // One minute before the window opens: check then, not ten minutes later.
        XCTAssertEqual(schedule.delay(after: time(8, 59)), 60, accuracy: 1)
        // Five minutes before the window closes: fall back to hourly at 19:00.
        XCTAssertEqual(schedule.delay(after: time(18, 55)), 300, accuracy: 1)
    }

    func testWorkingWindowIsTenHours() {
        XCTAssertEqual(AppUpdateCheckSchedule.workingHours.count, 10)
        XCTAssertEqual(AppUpdateCheckSchedule.workingHours.lowerBound, 9)
        XCTAssertEqual(AppUpdateCheckSchedule.workingHours.upperBound, 19)
        XCTAssertEqual(AppUpdateCheckSchedule.activeInterval, 600)
        XCTAssertEqual(AppUpdateCheckSchedule.idleInterval, 3600)
    }
}
