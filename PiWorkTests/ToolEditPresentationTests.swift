import XCTest
@testable import PiWork

final class ToolEditPresentationTests: XCTestCase {
    private func preview(_ json: String, name: String = "edit") throws -> ToolEditPresentation? {
        let input = try JSONDecoder().decode(AgentHostJSONValue.self, from: Data(json.utf8))
        return ToolEditPresentation(name: name, rawInput: input, summary: "")
    }

    func testSingleReplacement() throws {
        let result = try preview(#"{"path":"App.swift","oldText":"old\nline","newText":"new\nline"}"#)
        XCTAssertEqual(result?.changes, [.init(path: "App.swift", oldText: "old\nline", newText: "new\nline")])
    }

    func testMultipleReplacementsAndEmptyStrings() throws {
        let result = try preview(#"{"path":"中文.swift","edits":[{"oldText":"","newText":"added"},{"oldText":"removed","newText":""}]}"#, name: "Editor")
        XCTAssertEqual(result?.changes.count, 2)
        XCTAssertEqual(result?.changes.last?.newText, "")
    }

    func testSummaryFallback() {
        let result = ToolEditPresentation(name: "edit", rawInput: nil,
            summary: #"{"path":"a","oldText":"before","newText":"after"}"#)
        XCTAssertEqual(result?.changes.first?.path, "a")
    }

    func testIncompleteAndUnrelatedInputsKeepJSONFallback() throws {
        for json in [
            #"{"path":"a","oldText":"before"}"#,
            #"{"path":"a","edits":[]}"#,
            #"{"path":"a","edits":[{"oldText":"a","newText":"b"},{}]}"#,
            #"{"oldText":"a","newText":"b"}"#
        ] {
            XCTAssertNil(try preview(json))
        }
        XCTAssertNil(try preview(#"{"path":"a","oldText":"a","newText":"b"}"#, name: "bash"))
    }
}
