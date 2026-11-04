import XCTest
@testable import PiWork

final class TranscriptWindowNavigationTests: XCTestCase {
    func testHistoryNeverGrowsBeyondOneHundredSources() {
        let ids = (0..<1000).map(String.init)
        var window = TranscriptWindowNavigation()
        for _ in 0..<20 {
            XCTAssertEqual(window.range(in: ids).count, 100)
            window.revealEarlier(in: ids)
        }
        XCTAssertEqual(window.range(in: ids), 0..<100)
    }

    func testMovementRetainsTheWholeVisibleSourceIntervalWhenRequested() {
        let ids = (0..<1000).map(String.init)
        var window = TranscriptWindowNavigation()
        window.jump(to: "500", in: ids)
        let before = window.range(in: ids)
        let visibleFirst = before.lowerBound + 15
        window.revealNewer(in: ids, retainingFromID: String(visibleFirst))
        XCTAssertEqual(window.range(in: ids).lowerBound, visibleFirst)
        let later = window.range(in: ids)
        let visibleLast = later.upperBound - 10
        window.revealEarlier(in: ids, retainingThroughID: String(visibleLast))
        XCTAssertTrue(window.range(in: ids).contains(visibleLast))
        XCTAssertEqual(window.range(in: ids).count, 100)
    }

    func testEmptyAndShortSessionsAreSafe() {
        var window = TranscriptWindowNavigation()
        window.revealEarlier(in: [])
        window.revealNewer(in: [])
        window.jump(to: "missing", in: [])
        XCTAssertEqual(window.range(in: []), 0..<0)
        let ids = ["one", "two"]
        window.pin(in: ids)
        window.revealEarlier(in: ids)
        XCTAssertEqual(window.range(in: ids), 0..<2)
        window.revealLatest()
        XCTAssertEqual(window.range(in: ids), 0..<2)
    }

    func testMovingEarlierAndLaterKeepsOverlapAndHasABoundedWindow() {
        let ids = (0..<1500).map(String.init)
        var window = TranscriptWindowNavigation()
        XCTAssertEqual(Array(ids[window.range(in: ids)]), Array(ids[1400..<1500]))
        for _ in 0..<12 {
            let before = window.range(in: ids)
            window.revealEarlier(in: ids)
            let after = window.range(in: ids)
            XCTAssertLessThanOrEqual(after.count, TranscriptWindowNavigation.maximumCount)
            XCTAssertTrue(after.contains(before.lowerBound))
            XCTAssertLessThan(after.lowerBound, before.lowerBound)
        }
        for _ in 0..<12 {
            let before = window.range(in: ids)
            window.revealNewer(in: ids)
            let after = window.range(in: ids)
            XCTAssertTrue(after.contains(before.upperBound - 1))
            XCTAssertGreaterThanOrEqual(after.upperBound, before.upperBound)
        }
        XCTAssertEqual(window.range(in: ids).upperBound, ids.count)
    }

    func testReadingHistoryDoesNotMoveWhenNewMessagesArrive() {
        var ids = (0..<500).map(String.init)
        var window = TranscriptWindowNavigation()
        for _ in 0..<5 { window.revealEarlier(in: ids) }
        let before = Array(ids[window.range(in: ids)])
        ids.append(contentsOf: ["500", "501"])
        XCTAssertEqual(Array(ids[window.range(in: ids)]), before)
        window.revealLatest()
        XCTAssertEqual(ids[window.range(in: ids)].last, "501")
    }

    func testPausingAtRecentHistoryPinsTheVisibleRowsAcrossStreamingUpdates() {
        var ids = (0..<100).map(String.init)
        var window = TranscriptWindowNavigation()
        window.pin(in: ids)
        let before = Array(ids[window.range(in: ids)])
        ids += ["100", "101"]
        XCTAssertEqual(Array(ids[window.range(in: ids)]), before)
        window.followTail()
        XCTAssertEqual(ids[window.range(in: ids)].last, "101")
    }

    func testRevealingFinalWindowDoesNotFollowNewMessagesUntilReaderReachesBottom() {
        var ids = (0..<200).map(String.init)
        var window = TranscriptWindowNavigation()
        for _ in 0..<5 { window.revealEarlier(in: ids) }
        while window.range(in: ids).upperBound < ids.count { window.revealNewer(in: ids) }
        let before = Array(ids[window.range(in: ids)])
        ids.append("200")
        XCTAssertEqual(Array(ids[window.range(in: ids)]), before)
        window.followTail()
        XCTAssertEqual(ids[window.range(in: ids)].last, "200")
    }

    func testJumpToOldPromptKeepsTargetInBoundedWindow() {
        let ids = (0..<1000).map(String.init)
        var window = TranscriptWindowNavigation()
        window.jump(to: "120", in: ids)
        let range = window.range(in: ids)
        XCTAssertTrue(range.contains(120))
        XCTAssertLessThanOrEqual(range.count, TranscriptWindowNavigation.maximumCount)
        XCTAssertGreaterThan(range.upperBound, 121)
        window.revealLatest()
        XCTAssertEqual(window.range(in: ids).upperBound, ids.count)
    }

    func testPrependingRemoteHistoryPreservesTheExistingWindow() {
        var ids = (200..<400).map(String.init)
        var window = TranscriptWindowNavigation()
        for _ in 0..<3 { window.revealEarlier(in: ids) }
        let before = Array(ids[window.range(in: ids)])
        ids.insert(contentsOf: (160..<200).map(String.init), at: 0)
        let restored = Array(ids[window.range(in: ids)])
        XCTAssertTrue(before.allSatisfy(restored.contains))
        window.revealEarlier(in: ids)
        XCTAssertEqual(ids[window.range(in: ids)].first, "160")
    }
}
