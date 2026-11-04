import XCTest
@testable import PiWork

final class ToolCallPresentationTests: XCTestCase {
    func testWriteCountsLinesWithoutCountingTheTrailingNewlineAsAnExtraLine() {
        let cases: [(String, Int)] = [
            ("", 0),
            ("hello", 1),
            ("hello\n", 1),
            ("first\nsecond", 2),
            ("first\nsecond\n", 2),
            ("\n", 1),
            ("first\n\n", 2),
            ("first\r\nsecond\r\n", 2),
            ("你好 👋\n世界", 2)
        ]
        for (content, expected) in cases {
            let tool = SessionToolRecord(id: "write", name: "write", summary: "", rawInput: .object([
                "path": .string("file.txt"), "content": .string(content)
            ]), state: .completed, isError: false)
            let presentation = ToolCallPresentation(tool: tool)
            XCTAssertEqual(presentation.writtenLineCount, expected, "Content: \(content.debugDescription)")
            XCTAssertEqual(presentation.summary, "file.txt")
        }
    }

    func testWriteLineCountSupportsSummaryJSONFallback() {
        let tool = SessionToolRecord(id: "write", name: "Write",
            summary: #"{"path":"file.txt","content":"first\nsecond\n"}"#,
            state: .completed, isError: false)
        XCTAssertEqual(ToolCallPresentation(tool: tool).writtenLineCount, 2)
    }

    func testWriteLineCountIsHiddenForMissingOrIncompleteContentAndOtherTools() {
        for summary in ["", #"{"path":"file.txt"}"#, #"{"path":"file.txt","content":null}"#,
                        #"{"path":"file.txt","content":"partial"#] {
            let tool = SessionToolRecord(id: "write", name: "write", summary: summary,
                state: .running, isError: nil)
            XCTAssertNil(ToolCallPresentation(tool: tool).writtenLineCount)
        }
        let read = SessionToolRecord(id: "read", name: "read", summary: "", rawInput: .object([
            "path": .string("file.txt"), "content": .string("first\nsecond")
        ]), state: .completed, isError: false)
        XCTAssertNil(ToolCallPresentation(tool: read).writtenLineCount)
    }

    func testEditUsesHighlighterIconIncludingEditorAlias() {
        for name in ["edit", "editor", "Editor"] {
            let tool = SessionToolRecord(id: name, name: name, summary: "", state: .completed, isError: nil)
            XCTAssertEqual(ToolCallPresentation(tool: tool).iconName, "highlighter")
        }
    }

    func testBashInputShowsOnlyCommand() throws {
        let input = try JSONDecoder().decode(AgentHostJSONValue.self, from: Data(
            #"{"command":"echo \"hello\"\npwd","timeout":120}"#.utf8
        ))
        let tool = SessionToolRecord(id: "bash", name: "bash", summary: "", rawInput: input, state: .completed, isError: nil)
        XCTAssertEqual(ToolCallPresentation(tool: tool).formattedInput, "echo \"hello\"\npwd")
    }

    func testBashSummaryFallbackShowsOnlyCommand() {
        let tool = SessionToolRecord(id: "bash", name: "bash",
            summary: #"{"command":"git status","timeout":120}"#, state: .completed, isError: nil)
        XCTAssertEqual(ToolCallPresentation(tool: tool).formattedInput, "git status")
    }

    func testReadRangeIsCompact() {
        let tool = SessionToolRecord(id: "read", name: "read",
            summary: #"{"path":"App.swift","offset":3750,"limit":250}"#,
            state: .completed, isError: nil)
        XCTAssertEqual(ToolCallPresentation(tool: tool).formattedInput,
            "App.swift  ·  offset: 3750  ·  limit: 250")
    }

    func testOtherToolsPreserveParametersWithoutOuterJSON() {
        let tool = SessionToolRecord(id: "search", name: "web_search",
            summary: #"{"query":"swift layout","numResults":5,"includeContent":true}"#,
            state: .completed, isError: nil)
        XCTAssertEqual(ToolCallPresentation(tool: tool).formattedInput,
            "query: swift layout\nincludeContent: true\nnumResults: 5")
    }

    func testPlainBashSummaryIsPreserved() {
        let tool = SessionToolRecord(id: "bash", name: "bash", summary: "pwd", state: .completed, isError: nil)
        XCTAssertEqual(ToolCallPresentation(tool: tool).formattedInput, "pwd")
    }

    func testReadInputShowsPathWithoutJSON() throws {
        let input = try JSONDecoder().decode(AgentHostJSONValue.self, from: Data(#"{"path":"README.md"}"#.utf8))
        let tool = SessionToolRecord(id: "read", name: "read", summary: "", rawInput: input, state: .completed, isError: nil)
        XCTAssertFalse(ToolCallPresentation(tool: tool).isBash)
        XCTAssertEqual(ToolCallPresentation(tool: tool).formattedInput, "README.md")
    }
}
