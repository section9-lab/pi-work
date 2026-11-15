import MarkdownUI
import XCTest
@testable import PiWork

final class StreamingMarkdownAccumulatorTests: XCTestCase {
    func testIncrementalContentMatchesFullParseForStableDocuments() {
        let fixtures = [
            "# Title\n\nFirst paragraph with **bold** and `code`.\n\nSecond paragraph.",
            "Intro\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter the fence.",
            "Intro\n\n- first\n\n- second\n\n- third\n\nDone.",
            "Intro\n\n1. first\n\n2. second\n\nDone.",
            "Intro\n\n> quoted line\n> another\n\nAfter the quote.",
            "Intro\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nAfter the table.",
            "Before\n\n---\n\nAfter."
        ]

        for fixture in fixtures {
            let streamed = streamedContent(fixture)
            let full = MarkdownContent(fixture)
            XCTAssertEqual(
                streamed.renderMarkdown(),
                full.renderMarkdown(),
                "Block structure changed for fixture:\n\(fixture)"
            )
            XCTAssertEqual(
                streamed.renderPlainText(),
                full.renderPlainText(),
                "Plain text changed for fixture:\n\(fixture)"
            )
        }
    }

    func testBoundaryDoesNotFreezeInsideAnOpenFence() {
        let text = "before\n\n```\ncode\n\nmore\n```\n\nafter"
        let boundary = StreamingMarkdownBoundary.stablePrefixEnd(in: text)
        XCTAssertEqual(String(text[..<boundary]), "before\n\n```\ncode\n\nmore\n```\n\n")
    }

    func testBoundaryDoesNotSplitBlockquotesListsOrTables() {
        let quote = "intro\n\n> one\n>\n> two\n\nafter"
        XCTAssertEqual(
            String(quote[..<StreamingMarkdownBoundary.stablePrefixEnd(in: quote)]),
            "intro\n\n> one\n>\n> two\n\n"
        )

        let list = "- one\n\n- two\n\nend"
        XCTAssertEqual(
            String(list[..<StreamingMarkdownBoundary.stablePrefixEnd(in: list)]),
            "- one\n\n- two\n\n"
        )

        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |\n\nend"
        XCTAssertEqual(
            String(table[..<StreamingMarkdownBoundary.stablePrefixEnd(in: table)]),
            "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n"
        )
    }

    func testReferenceDefinitionsDisableIncrementalParsing() {
        let text = "A paragraph.\n\n[link]: https://example.com\n\nAnother paragraph."
        let boundary = StreamingMarkdownBoundary.stablePrefixEnd(in: text)
        XCTAssertEqual(boundary, text.startIndex)
    }

    func testLaterReferenceDefinitionForcesAFullReparse() {
        var accumulator = StreamingMarkdownAccumulator()
        _ = accumulator.content(for: "See [docs].\n\n")
        let text = "See [docs].\n\n[docs]: https://example.com\n\nMore."
        let content = accumulator.content(for: text)
        XCTAssertEqual(content.renderPlainText(), MarkdownContent(text).renderPlainText())
    }

    func testAccumulatorResetsWhenTextShrinks() {
        var accumulator = StreamingMarkdownAccumulator()
        _ = accumulator.content(for: "one\n\ntwo\n\nthree")
        let shrunk = accumulator.content(for: "one\n\ntwo")
        XCTAssertEqual(
            shrunk.renderMarkdown(),
            MarkdownContent("one\n\ntwo").renderMarkdown()
        )
    }

    func testStreamingReparsesFarLessThanTheWholeDocument() {
        let paragraph = String(repeating: "word ", count: 40) + "\n\n"
        let text = String(repeating: paragraph, count: 200)
        var accumulator = StreamingMarkdownAccumulator()
        var content = MarkdownContent("")
        var offset = 0
        let step = 320

        while offset < text.count {
            offset = min(text.count, offset + step)
            content = accumulator.content(for: String(text.prefix(offset)))
        }

        // A full reparse would touch roughly 200 prefixed documents (~4M chars).
        print("STREAMING_MARKDOWN parsed=\(accumulator.parsedCharacterCount) text=\(text.count)")
        XCTAssertLessThan(
            accumulator.parsedCharacterCount,
            text.count * 3,
            "Incremental parsing should stay proportional to the document"
        )
        XCTAssertEqual(
            content.renderPlainText(),
            MarkdownContent(text).renderPlainText()
        )
    }

    func testSegmenterMatchesAFullParseBlockForBlock() {
        let fixtures = [
            "# Title\n\nFirst paragraph with **bold** and `code`.\n\nSecond paragraph.",
            "Intro\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter the fence.",
            "Intro\n\n- first\n\n- second\n\n- third\n\nDone.",
            "Intro\n\n1. first\n\n2. second\n\nDone.",
            "Intro\n\n> quoted line\n> another\n\nAfter the quote.",
            "Intro\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nAfter the table.",
            "Before\n\n---\n\nAfter."
        ]

        for fixture in fixtures {
            var segmenter = StreamingMarkdownSegmenter()
            var segments: [StreamingMarkdownSegment] = []
            var offset = 0
            while offset < fixture.count {
                offset = min(fixture.count, offset + 5)
                segments = segmenter.segments(for: String(fixture.prefix(offset)))
            }

            let joined = segments
                .map { $0.content.renderMarkdown() }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            XCTAssertEqual(
                joined.trimmingCharacters(in: .whitespacesAndNewlines),
                MarkdownContent(fixture).renderMarkdown()
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                "Segments must reproduce the full parse for:\n\(fixture)"
            )
            XCTAssertGreaterThan(segments.count, 1, "Fixture should split: \(fixture)")
        }
    }

    func testSegmenterFreezesCompletedSegments() {
        var segmenter = StreamingMarkdownSegmenter()
        _ = segmenter.segments(for: "one\n\ntwo\n\n")
        let frozen = segmenter.segments(for: "one\n\ntwo\n\nthree")
        let parsedBefore = segmenter.parsedCharacterCount

        // Growing the tail must not replace any completed segment; only the
        // tail itself is parsed again.
        let appended = segmenter.segments(for: "one\n\ntwo\n\nthree four five")
        XCTAssertEqual(Array(appended.prefix(frozen.count - 1)), Array(frozen.prefix(frozen.count - 1)))
        XCTAssertEqual(
            segmenter.parsedCharacterCount - parsedBefore,
            "three four five".count,
            "Only the tail should be reparsed"
        )
    }

    func testSegmenterKeepsStableIdentifiersWhileAppending() {
        var segmenter = StreamingMarkdownSegmenter()
        let first = segmenter.segments(for: "a\n\nb")
        let second = segmenter.segments(for: "a\n\nb\n\nc")
        XCTAssertEqual(Array(second.prefix(first.count)).map(\.id), first.map(\.id))
    }

    func testSegmenterResetsWhenALinkReferenceAppears() {
        var segmenter = StreamingMarkdownSegmenter()
        _ = segmenter.segments(for: "See [docs].\n\n")
        let segments = segmenter.segments(for: "See [docs].\n\n[docs]: https://example.com\n\nMore.")
        XCTAssertEqual(segments.count, 1, "Unsplittable documents fall back to one segment")
        XCTAssertEqual(
            segments[0].content.renderPlainText(),
            MarkdownContent("See [docs].\n\n[docs]: https://example.com\n\nMore.").renderPlainText()
        )
    }

    func testSegmenterDiscardsFrozenWorkWhenTextShrinks() {
        var segmenter = StreamingMarkdownSegmenter()
        _ = segmenter.segments(for: "one\n\ntwo\n\nthree")
        let segments = segmenter.segments(for: "one\n\ntwo")
        XCTAssertEqual(
            segments.map { $0.content.renderMarkdown() }.joined(separator: "\n\n"),
            MarkdownContent("one\n\ntwo").renderMarkdown()
        )
    }

    private func streamedContent(_ text: String) -> MarkdownContent {
        var accumulator = StreamingMarkdownAccumulator()
        var content = MarkdownContent("")
        var offset = 0
        while offset < text.count {
            offset = min(text.count, offset + 7)
            content = accumulator.content(for: String(text.prefix(offset)))
        }
        return content
    }

    /// The segmented view reproduces `BlockSequence` spacing by carrying the
    /// margins of the GitHub theme, so these values must track that theme.
    func testSegmentMarginsMatchGitHubTheme() {
        XCTAssertEqual(StreamingMarkdownBlockMargin.leading(of: "## Heading\n\ntext"), 24)
        XCTAssertEqual(StreamingMarkdownBlockMargin.leading(of: "plain paragraph"), 0)
        XCTAssertEqual(StreamingMarkdownBlockMargin.leading(of: "---\n\ntext"), 24)
        XCTAssertEqual(StreamingMarkdownBlockMargin.leading(of: "- item"), 0)

        XCTAssertEqual(StreamingMarkdownBlockMargin.trailing(of: "text\n\n"), 16)
        XCTAssertEqual(StreamingMarkdownBlockMargin.trailing(of: "text"), 16)
        XCTAssertEqual(StreamingMarkdownBlockMargin.trailing(of: "text\n\n---\n\n"), 24)
        XCTAssertEqual(StreamingMarkdownBlockMargin.trailing(of: "text\n\n- a\n\n- b\n\n"), 0)
        XCTAssertEqual(StreamingMarkdownBlockMargin.trailing(of: "> quoted\n\n"), 0)
    }

    func testSegmenterCarriesMarginsForAdjacentBlocks() {
        var segmenter = StreamingMarkdownSegmenter()
        let segments = segmenter.segments(for: "Intro\n\n## Heading\n\nBody\n\n")
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].trailingMargin, 16)
        XCTAssertEqual(segments[1].leadingMargin, 24)
        XCTAssertEqual(segments[1].trailingMargin, 16)
        XCTAssertEqual(segments[2].leadingMargin, 0)
    }
}
