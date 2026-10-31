import XCTest
@testable import PiWork

final class AgentErrorPresentationTests: XCTestCase {
    func testProtocolDumpBecomesAnUnreachableUpstream() {
        let notice = AgentErrorPresentation(
            rawMessage: #"requestFailed(code: "invalid_request", message: "Unable to connect. Is the computer able to access the url?")"#
        )

        XCTAssertEqual(notice.kind, .upstreamUnreachable)
        XCTAssertFalse(notice.title.contains("requestFailed"))
        XCTAssertFalse(notice.title.contains("invalid_request"))
        XCTAssertEqual(notice.technicalDetail?.isEmpty, false)
    }

    func testHostMessageKeepsItsOwnWording() {
        let message = "The session stopped because the context window is full."
        let notice = AgentErrorPresentation(rawMessage: message)

        XCTAssertEqual(notice.kind, .internalFailure)
        XCTAssertEqual(notice.detail, message)
        XCTAssertNil(notice.technicalDetail)
    }

    func testClientErrorSplitsCodeAndMessage() {
        let notice = AgentErrorPresentation(
            AgentHostClientError.requestFailed(code: "unauthorized", message: "401")
        )

        XCTAssertEqual(notice.kind, .authentication)
        XCTAssertEqual(notice.technicalDetail, "unauthorized\n401")
    }

    func testRequestTimeoutIsSanitized() {
        let notice = AgentErrorPresentation(
            AgentHostClientError.requestFailed(code: "upstream_unreachable", message: "timed out")
        )

        XCTAssertEqual(notice.kind, .timeout)
    }

    func testBusySessionKeepsItsOwnCopy() {
        let notice = AgentErrorPresentation(SessionStoreError.sessionBusy("session"))

        XCTAssertEqual(notice.kind, .busy)
    }

    func testEscapedQuotesInDumpAreUnescaped() {
        let notice = AgentErrorPresentation(
            rawMessage: #"requestFailed(code: "invalid_request", message: "Upstream said \"no\" once.")"#
        )

        XCTAssertEqual(notice.technicalDetail, "invalid_request\nUpstream said \"no\" once.")
    }

    func testInformationalNoticeShowsOnlyItsMessage() {
        let notice = AgentErrorPresentation(informational: "Still processing the image.")

        XCTAssertEqual(notice.kind, .informational)
        XCTAssertEqual(notice.title, "Still processing the image.")
        XCTAssertNil(notice.technicalDetail)
    }
}
