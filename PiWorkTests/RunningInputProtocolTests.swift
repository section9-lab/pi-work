import Foundation
import XCTest
@testable import PiWork

final class RunningInputProtocolTests: XCTestCase {
    func testDecodesNativeQueueNotificationWithImageMetadata() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"_piWork/session.inputQueueChanged","params":{"sessionId":"one","sequence":7,"inputs":[{"id":"input","text":"next","behavior":"followUp","images":[{"type":"image","mimeType":"image/png","data":"AQID"}]}]}}"#.utf8)
        guard case .sessionInputQueueChanged(let payload) = try AgentHostServerEvent.decode(from: data) else {
            return XCTFail("Expected queue event")
        }
        XCTAssertEqual(payload.sequence, 7)
        XCTAssertEqual(payload.inputs.first?.behavior, .followUp)
        XCTAssertEqual(payload.inputs.first?.images.first?.data, Data([1, 2, 3]))
        XCTAssertNil(payload.recoveredInputs)
    }

    func testDecodesDeliveredInputWithoutInventingANewRun() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"_piWork/session.inputDelivered","params":{"sessionId":"one","sequence":8,"input":{"id":"input","text":"next","behavior":"steer","images":[]}}}"#.utf8)
        guard case .sessionInputDelivered(let payload) = try AgentHostServerEvent.decode(from: data) else {
            return XCTFail("Expected delivered event")
        }
        XCTAssertEqual(payload.input.id, "input")
        XCTAssertEqual(payload.input.behavior, .steer)
    }
}
