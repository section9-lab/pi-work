import XCTest
@testable import PiWork

final class SessionUnreadStateTests: XCTestCase {
    func testBackgroundCompletionBecomesUnread() {
        var state = SessionUnreadState()

        state.update(activeSessionIDs: ["background"], visibleSessionID: "visible")
        XCTAssertTrue(state.unreadSessionIDs.isEmpty)

        state.update(activeSessionIDs: [], visibleSessionID: "visible")
        XCTAssertEqual(state.unreadSessionIDs, ["background"])
    }

    func testVisibleCompletionDoesNotBecomeUnread() {
        var state = SessionUnreadState()

        state.update(activeSessionIDs: ["visible"], visibleSessionID: "visible")
        state.update(activeSessionIDs: [], visibleSessionID: "visible")

        XCTAssertTrue(state.unreadSessionIDs.isEmpty)
    }

    func testViewingAnUnreadSessionClearsTheDot() {
        var state = SessionUnreadState()
        state.update(activeSessionIDs: ["background"], visibleSessionID: nil)
        state.update(activeSessionIDs: [], visibleSessionID: nil)
        XCTAssertEqual(state.unreadSessionIDs, ["background"])

        state.markViewed("background")

        XCTAssertTrue(state.unreadSessionIDs.isEmpty)
    }

    func testRestartingAFinishedSessionClearsTheStaleDot() {
        var state = SessionUnreadState()
        state.update(activeSessionIDs: ["session"], visibleSessionID: nil)
        state.update(activeSessionIDs: [], visibleSessionID: nil)
        XCTAssertEqual(state.unreadSessionIDs, ["session"])

        state.update(activeSessionIDs: ["session"], visibleSessionID: nil)

        XCTAssertTrue(state.unreadSessionIDs.isEmpty)
    }

    func testDeletingASessionDropsItsUnreadState() {
        var state = SessionUnreadState()
        state.update(activeSessionIDs: ["session"], visibleSessionID: nil)
        state.update(activeSessionIDs: [], visibleSessionID: nil)

        state.remove("session")

        XCTAssertTrue(state.unreadSessionIDs.isEmpty)
    }

    func testOnlySessionsLeavingActivityBecomeUnread() {
        var state = SessionUnreadState()
        state.update(activeSessionIDs: ["first", "second"], visibleSessionID: nil)

        state.update(activeSessionIDs: ["second"], visibleSessionID: nil)

        XCTAssertEqual(state.unreadSessionIDs, ["first"])
    }
}
