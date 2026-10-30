import XCTest
@testable import PiWork

@MainActor
final class AssistantMarkdownPresentationTests: XCTestCase {
    func testContinuousStreamingCoalescesAndRendersTheLatestText() async throws {
        let presentation = AssistantMarkdownPresentation(text: "", delayNanoseconds: 30_000_000)
        for index in 1...20 {
            presentation.update(text: "revision \(index)", isStreaming: true)
        }
        XCTAssertEqual(presentation.renderedText, "")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(presentation.renderedText, "revision 20")

        presentation.update(text: "next window", isStreaming: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(presentation.renderedText, "next window")
        presentation.cancel()
    }

    func testCompletionFlushesImmediatelyWithoutWaitingForTheStreamingTimer() async throws {
        let presentation = AssistantMarkdownPresentation(text: "", delayNanoseconds: 30_000_000)
        presentation.update(text: "partial", isStreaming: true)
        presentation.update(text: "**complete**", isStreaming: false)
        XCTAssertEqual(presentation.renderedText, "**complete**")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(presentation.renderedText, "**complete**")
    }

    func testDisappearanceCancelsPendingWorkAndReappearanceCanResume() async throws {
        let presentation = AssistantMarkdownPresentation(text: "initial", delayNanoseconds: 30_000_000)
        presentation.update(text: "latest", isStreaming: true)
        presentation.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(presentation.renderedText, "initial")

        presentation.update(text: "latest", isStreaming: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(presentation.renderedText, "latest")
    }
}
