import CoreGraphics
import XCTest
@testable import PiWork

final class TranscriptVirtualizationTests: XCTestCase {
    func testRowsOutsideTheBufferUsePlaceholders() {
        let rows = makeRows(count: 4)
        let frames: [String: CGRect] = [
            "0": CGRect(x: 0, y: 0, width: 600, height: 80),
            "1": CGRect(x: 0, y: 700, width: 600, height: 80),
            "2": CGRect(x: 0, y: 2_000, width: 600, height: 80),
            "3": CGRect(x: 0, y: -1_200, width: 600, height: 80)
        ]

        let mounted = TranscriptVirtualization.mountedRowIDs(
            rows: rows,
            viewportHeight: 600,
            buffer: 900,
            isMeasured: { _ in true },
            frame: { frames[$0.message.id] },
            mustMount: { _ in false }
        )

        XCTAssertEqual(mounted, Set([rows[0].id, rows[1].id]))
    }

    func testUnmeasuredAndMutatingRowsAlwaysMount() {
        let rows = makeRows(count: 3)
        let frames: [String: CGRect] = [
            "0": CGRect(x: 0, y: 5_000, width: 600, height: 80),
            "1": CGRect(x: 0, y: 5_000, width: 600, height: 80),
            "2": CGRect(x: 0, y: 6_000, width: 600, height: 80)
        ]

        let mounted = TranscriptVirtualization.mountedRowIDs(
            rows: rows,
            viewportHeight: 600,
            buffer: 300,
            isMeasured: { $0.message.id != "1" },
            frame: { frames[$0.message.id] },
            mustMount: { $0.message.id == "2" }
        )

        XCTAssertEqual(mounted, Set([rows[1].id, rows[2].id]))
    }

    func testNoViewportRendersEveryRow() {
        let rows = makeRows(count: 2)
        XCTAssertNil(TranscriptVirtualization.mountedRowIDs(
            rows: rows,
            viewportHeight: 0,
            buffer: 0,
            isMeasured: { _ in true },
            frame: { _ in CGRect(x: 0, y: 5_000, width: 600, height: 80) },
            mustMount: { _ in false }
        ))
    }

    private func makeRows(count: Int) -> [TranscriptVisibleRow] {
        (0..<count).map { index in
            TranscriptVisibleRow(
                id: .message(String(index)),
                message: PiChatMessage(
                    id: String(index),
                    role: .user,
                    parts: [.text(id: "\(index):text", text: "Row \(index)")],
                    timestamp: nil,
                    isStreaming: false
                )
            )
        }
    }
}
