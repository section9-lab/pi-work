import XCTest
@testable import PiWork

@MainActor
final class ToolInputPresentationCacheTests: XCTestCase {
    func testOutputAndExecutionChangesReuseInputPresentation() throws {
        let cache = ToolInputPresentationCache()
        let input = try JSONDecoder().decode(AgentHostJSONValue.self, from: Data(
            #"{"path":"a.swift","oldText":"old\ncontext","newText":"new\ncontext"}"#.utf8))
        let first = cache.value(for: SessionToolRecord(id: "edit", name: "edit", summary: "", rawInput: input, state: .running, isError: nil))
        let completed = cache.value(for: SessionToolRecord(id: "edit", name: "edit", summary: "", output: "Finished", rawInput: input, state: .completed, isError: false))
        XCTAssertTrue(first === completed)
        XCTAssertEqual(completed.call.summary, "a.swift")
        XCTAssertEqual(completed.edit?.diffSummary.additions, 1)
        XCTAssertEqual(completed.edit?.diffSummary.deletions, 1)
    }

    func testWriteLineCountUpdatesWithInputAndIsReusedOnCompletion() {
        let cache = ToolInputPresentationCache()
        func tool(content: String, state: SessionToolRunState) -> SessionToolRecord {
            SessionToolRecord(id: "write", name: "write", summary: "", rawInput: .object([
                "path": .string("file.txt"), "content": .string(content)
            ]), state: state, isError: nil)
        }
        let first = cache.value(for: tool(content: "first\n", state: .running))
        let updated = cache.value(for: tool(content: "first\nsecond\n", state: .running))
        let completed = cache.value(for: tool(content: "first\nsecond\n", state: .completed))

        XCTAssertEqual(first.call.writtenLineCount, 1)
        XCTAssertEqual(updated.call.writtenLineCount, 2)
        XCTAssertFalse(first === updated)
        XCTAssertTrue(updated === completed)
    }

    func testChangedArgumentsInvalidatePresentationEvenWhenSummaryIsUnchanged() {
        let cache = ToolInputPresentationCache()
        let first = cache.value(for: SessionToolRecord(id: "read", name: "read", summary: "", rawInput: .object(["path": .string("first.swift")]), state: .running, isError: nil))
        let second = cache.value(for: SessionToolRecord(id: "read", name: "read", summary: "", rawInput: .object(["path": .string("second.swift")]), state: .running, isError: nil))
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.call.formattedInput, "second.swift")
    }
}
