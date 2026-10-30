import XCTest
@testable import PiWork

final class ToolCallPresentationTests: XCTestCase {
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
