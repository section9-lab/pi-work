import XCTest
@testable import PiWork

final class PromptRailPresentationTests: XCTestCase {
    func testEachUserTurnGetsOneMarkIncludingImageOnlyPrompts() {
        let messages = [
            PiChatMessage(id: "u1", role: .user, text: "First question", timestamp: nil, isStreaming: false),
            PiChatMessage(id: "a1", role: .assistant, text: "Reply", timestamp: nil, isStreaming: false),
            PiChatMessage(id: "u2", role: .user, parts: [
                .image(id: "image", mimeType: "image/png", data: Data([1]))
            ], timestamp: nil, isStreaming: false),
            PiChatMessage(id: "empty", role: .user, text: " \n", timestamp: nil, isStreaming: false)
        ]
        let entries = PromptRailPresentation.entries(from: messages)
        XCTAssertEqual(entries.map(\.id), ["u1", "u2"])
        XCTAssertEqual(entries.map(\.index), [1, 2])
        XCTAssertFalse(entries[1].hasText)
        XCTAssertEqual(entries[1].imageCount, 1)
    }

    func testHoverPromptRetainsFullTextAndParagraphs() throws {
        let text = "First paragraph\n\n" + String(repeating: "More detail. ", count: 80)
        let message = PiChatMessage(id: "long", role: .user, text: text, timestamp: nil, isStreaming: false)
        let entry = try XCTUnwrap(PromptRailPresentation.entries(from: [message]).first)
        XCTAssertEqual(entry.fullText, text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(entry.text.hasSuffix("…"))
        XCTAssertLessThan(entry.text.count, entry.fullText.count)
    }

    func testMarksOnlyLengthenWhileRegionIsExpanded() {
        XCTAssertEqual(PromptRailLayout.markWidth(isExpanded: false, isHovered: false), PromptRailLayout.restingWidth)
        XCTAssertEqual(PromptRailLayout.markWidth(isExpanded: false, isHovered: true), PromptRailLayout.restingWidth)
        XCTAssertGreaterThan(PromptRailLayout.markWidth(isExpanded: true, isHovered: false), PromptRailLayout.restingWidth)
        XCTAssertGreaterThan(PromptRailLayout.markWidth(isExpanded: true, isHovered: true), PromptRailLayout.expandedWidth)
    }

    func testLongSessionsScrollWithStableNonoverlappingTargets() {
        let centers = PromptRailLayout.tickCenters(count: 200, height: 300)
        XCTAssertEqual(centers.count, 200)
        XCTAssertEqual(PromptRailLayout.step(for: centers), PromptRailLayout.minimumStep)
        XCTAssertGreaterThan(centers.last ?? 0, 300)
        XCTAssertLessThanOrEqual(PromptRailLayout.railHeight(count: 200, available: 300), 300)
        XCTAssertEqual(PromptRailLayout.index(atY: centers[130], centers: centers), 130)
    }

    func testPreviewStaysInsideViewportAtBothEdges() {
        XCTAssertEqual(PromptRailLayout.previewTop(center: 0, cardHeight: 80, height: 200), 0)
        XCTAssertEqual(PromptRailLayout.previewTop(center: 100, cardHeight: 80, height: 200), 60)
        XCTAssertEqual(PromptRailLayout.previewTop(center: 200, cardHeight: 80, height: 200), 120)
        XCTAssertEqual(PromptRailLayout.previewTop(center: 20, cardHeight: 80, height: 40), 0)
    }

    func testSmallViewportNeverGetsAnOversizedRail() {
        XCTAssertEqual(PromptRailLayout.railHeight(count: 20, available: 40), 40)
        XCTAssertEqual(PromptRailLayout.railHeight(count: 20, available: -10), 0)
    }
}
