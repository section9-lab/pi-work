import XCTest
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

    func testUpdateBannerFitsNarrowWindowsAndBothAppearances() throws {
        let controller = AppUpdateController()
        controller.offerUpdate(version: "0.2.0") { _ in }
        for width: CGFloat in [436, 620, 900] {
            for scheme in [ColorScheme.light, .dark] {
                let view = NSHostingController(rootView: AppUpdateBanner(controller: controller)
                    .environment(\.colorScheme, scheme))
                XCTAssertLessThanOrEqual(view.sizeThatFits(in: CGSize(width: width, height: 400)).width, width)
            }
        }
    }
}
