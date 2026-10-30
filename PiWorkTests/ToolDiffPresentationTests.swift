import XCTest
@testable import PiWork

final class ToolDiffPresentationTests: XCTestCase {
    func testReplacementPreservesContext() {
        let diff = ToolDiffPresentation(oldText: "first\nold\nlast\n", newText: "first\nnew\nlast\n")
        XCTAssertEqual(diff.lines.map(\.text), ["first", "old", "new", "last"])
        XCTAssertEqual(diff.lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 1)
    }

    func testNewFileAndEmptyInput() {
        let diff = ToolDiffPresentation(oldText: nil, newText: "a\nb\n")
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 0)
        XCTAssertTrue(ToolDiffPresentation(oldText: "", newText: "").lines.isEmpty)
    }

    func testDeletionAndRepeatedLines() {
        let diff = ToolDiffPresentation(oldText: "a\na\nb", newText: "a\nb")
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.additions, 0)
        XCTAssertEqual(diff.lines.filter { $0.kind != .removed }.map(\.text), ["a", "b"])
    }
}
