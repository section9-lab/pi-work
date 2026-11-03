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

    func testChangedArgumentsInvalidatePresentationEvenWhenSummaryIsUnchanged() {
        let cache = ToolInputPresentationCache()
        let first = cache.value(for: SessionToolRecord(id: "read", name: "read", summary: "", rawInput: .object(["path": .string("first.swift")]), state: .running, isError: nil))
        let second = cache.value(for: SessionToolRecord(id: "read", name: "read", summary: "", rawInput: .object(["path": .string("second.swift")]), state: .running, isError: nil))
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.call.formattedInput, "second.swift")
    }
}
