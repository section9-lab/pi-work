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
}
