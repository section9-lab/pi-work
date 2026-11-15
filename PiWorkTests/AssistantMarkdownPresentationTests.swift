import AppKit
import MarkdownUI
import SwiftUI
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

    func testInvisibleStreamingRowDefersParsingUntilAllowed() async throws {
        let presentation = AssistantMarkdownPresentation(text: "", delayNanoseconds: 5_000_000)
        presentation.renderAllowed = { false }
        presentation.update(text: "**hidden**", isStreaming: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(presentation.renderedText, "")

        presentation.renderAllowed = { true }
        presentation.update(text: "**visible**", isStreaming: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(presentation.renderedText, "**visible**")
        presentation.cancel()
    }

    func testCompletionFlushesEvenWhenStreamingRendersAreDeferred() {
        let presentation = AssistantMarkdownPresentation(text: "", delayNanoseconds: 5_000_000)
        presentation.renderAllowed = { false }
        presentation.update(text: "partial", isStreaming: true)
        presentation.update(text: "**complete**", isStreaming: false)
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

    func testBlockMemoStrategyPublishesStableSegmentsWhileStreaming() async throws {
        let original = AssistantMarkdownRendering.strategy
        AssistantMarkdownRendering.strategy = .blockMemo
        defer { AssistantMarkdownRendering.strategy = original }

        let presentation = AssistantMarkdownPresentation(text: "", delayNanoseconds: 20_000_000)
        let first = "Intro paragraph.\n\nSecond paragraph.\n\n"
        presentation.update(text: first, isStreaming: true)
        try await Task.sleep(nanoseconds: 120_000_000)
        let frozenIDs = presentation.segments.map(\.id)
        XCTAssertEqual(presentation.segments.count, 2, "Trailing blank line completes both blocks")

        presentation.update(text: first + "Third paragraph is still growing", isStreaming: true)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(Array(presentation.segments.map(\.id).prefix(frozenIDs.count)), frozenIDs)
        XCTAssertEqual(presentation.segments.count, 3)

        // Completion collapses back to one exact parse.
        presentation.update(text: first + "Third paragraph is done.", isStreaming: false)
        XCTAssertEqual(presentation.segments.count, 1)
        XCTAssertEqual(
            presentation.segments[0].content.renderMarkdown(),
            presentation.content.renderMarkdown()
        )
        presentation.cancel()
    }

    func testBlockMemoViewsLayOutWithoutCrashing() {
        let segments = [
            StreamingMarkdownSegment(id: 0, content: MarkdownContent("# Heading")),
            StreamingMarkdownSegment(id: 1, content: MarkdownContent("A paragraph with `code`.")),
            StreamingMarkdownSegment(id: 2, content: MarkdownContent("```\nlet a = 1\n```"))
        ]
        for mode in [AssistantMarkdownBlocksView.Mode.eager, .lazyStack, .windowed] {
            let view = AssistantMarkdownBlocksView(segments: segments, mode: mode, resetToken: 0)
                .frame(width: 420)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    /// Windowed blocks replace offscreen content with measured placeholders, so
    /// the document height must match an eager layout exactly. A mismatch here
    /// is what makes the transcript anchor drift.
    func testWindowedBlocksKeepTheSameGeometryAsEagerBlocks() {
        let segments = (0..<12).map { index in
            StreamingMarkdownSegment(
                id: index,
                content: MarkdownContent("Paragraph \(index) with enough text to wrap across the available width.")
            )
        }
        func height(_ mode: AssistantMarkdownBlocksView.Mode) -> CGFloat {
            let host = NSHostingView(
                rootView: AssistantMarkdownBlocksView(segments: segments, mode: mode, resetToken: 0).frame(width: 420))
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 4000)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded() }
            return host.fittingSize.height
        }
        let eager = height(.eager)
        XCTAssertGreaterThan(eager, 0)
        XCTAssertEqual(height(.windowed), eager, accuracy: 0.5)
    }

    /// Golden geometry check: rendering the block-segmented view must occupy
    /// exactly the same height as the single whole-document Markdown view.
    /// Segment margins are derived from MarkdownUI's `Theme.gitHub` block
    /// margins, so a mismatch means the spacing table is wrong.
    func testSegmentedLayoutMatchesWholeDocumentHeight() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/markdown/performance-complex.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        var segmenter = StreamingMarkdownSegmenter()
        let segments = segmenter.segments(for: text)
        XCTAssertGreaterThan(segments.count, 5)

        func height<V: View>(_ view: V) -> CGFloat {
            let host = NSHostingView(rootView: AnyView(view.frame(width: 520)))
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 8000)
            for _ in 0..<4 {
                RunLoop.current.run(until: Date())
                host.layoutSubtreeIfNeeded()
            }
            return host.fittingSize.height
        }

        let whole = height(Markdown(text).markdownTheme(.gitHub))
        let segmented = height(
            AssistantMarkdownBlocksView(segments: segments, mode: .eager, resetToken: 0)
                .markdownTheme(.gitHub))
        XCTAssertEqual(segmented, whole, accuracy: 0.5)
    }

    func testBlockWindowPolicy() {
        XCTAssertEqual(
            AssistantMarkdownBlocksView.mountedWindow(
                mode: .windowed, allMeasured: true, voiceOver: false),
            AssistantMarkdownBlocksView.mountedBlockWindow
        )
        // Unmeasured blocks (first pass, width change) stay mounted so they can
        // be measured at the new width.
        XCTAssertEqual(
            AssistantMarkdownBlocksView.mountedWindow(
                mode: .windowed, allMeasured: false, voiceOver: false),
            Int.max
        )
        // VoiceOver always reads the whole reply.
        XCTAssertEqual(
            AssistantMarkdownBlocksView.mountedWindow(
                mode: .windowed, allMeasured: true, voiceOver: true),
            Int.max
        )
        // Reading above the tail must never leave blocks as blank placeholders:
        // scroll does not re-invalidate SwiftUI every frame.
        XCTAssertEqual(
            AssistantMarkdownBlocksView.mountedWindow(
                mode: .windowed, allMeasured: true, voiceOver: false, followsTail: false),
            Int.max
        )
        XCTAssertEqual(
            AssistantMarkdownBlocksView.mountedWindow(
                mode: .eager, allMeasured: true, voiceOver: false),
            Int.max
        )
    }

    func testDefaultStrategyIsBlockWindow() {
        // The shipped default must be the geometry-safe windowed mode; the
        // environment override is what the acceptance benchmark uses.
        XCTAssertEqual(AssistantMarkdownRendering.strategy.logName, AssistantMarkdownRendering.Strategy.blockWindow.logName)
        XCTAssertTrue(AssistantMarkdownRendering.usesSegments)
        XCTAssertEqual(AssistantMarkdownRendering.blockMode, .windowed)
    }
}
