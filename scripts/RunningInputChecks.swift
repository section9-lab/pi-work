import Foundation

/// Queue/protocol regression checks that also run on Command Line Tools-only hosts.
@MainActor
struct RunningInputChecks {
    static func run() throws {
        let expect = MCPChecks.expect
        try expect(RunningMessageBehavior.resolve("") == .followUp, "Running input must default to follow-up")
        try expect(RunningMessageBehavior.resolve("future-value") == .followUp, "Unknown preference must fall back")
        try expect(RunningMessageBehavior.resolve("steer") == .steer, "Steer preference was ignored")
        let wire = Data(#"{"jsonrpc":"2.0","method":"_piWork/session.inputQueueChanged","params":{"sessionId":"one","sequence":1,"inputs":[{"id":"input","text":"next","behavior":"followUp","images":[{"type":"image","mimeType":"image/png","data":"AQID"}]}]}}"#.utf8)
        guard case .sessionInputQueueChanged(let queue) = try AgentHostServerEvent.decode(from: wire),
              let input = queue.inputs.first else { throw MCPChecks.Failure(message: "Queue event did not decode") }
        try expect(input.images.first?.data == Data([1, 2, 3]), "Queued image was lost in decoding")
        let snapshot = AgentHostSessionSnapshotResult(
            session: AgentHostSessionDescriptor(id: "one", path: "/tmp/one.jsonl", cwd: "/tmp", title: "Test"),
            messages: [], state: .running, sequence: 0, turnId: "run", model: nil,
            thinkingLevel: .off, availableThinkingLevels: [.off], accessMode: .full, pendingApprovals: [])
        var reducer = SessionStoreReducer()
        reducer.apply(snapshot: snapshot, profile: .work, sessionDirectory: nil)
        _ = reducer.receive(.sessionInputQueueChanged(queue), timestamp: "now")
        try expect(reducer.records["one"]?.queuedInputs == [input], "Queue state was not retained")
        try expect(reducer.records["one"]?.messages.isEmpty == true, "Queue appeared as a delivered message")
        try expect(reducer.records["one"]?.activeTurnId == "run", "Enqueue replaced the active run")
        let delivered = AgentHostServerEvent.sessionInputDelivered(AgentHostInputDeliveredPayload(
            sessionId: "one", sequence: 2, input: input))
        _ = reducer.receive(delivered, timestamp: "later")
        _ = reducer.receive(delivered, timestamp: "later")
        try expect(reducer.records["one"]?.messages.count == 1, "Delivered message was duplicated")
        try expect(reducer.records["one"]?.queuedInputs.isEmpty == true, "Delivered input remained queued")
        try expect(reducer.records["one"]?.messages.first?.content == [
            .text("next"), .image(mimeType: "image/png", data: Data([1, 2, 3]))
        ], "Delivery lost text or image")
        try expect(reducer.records["one"]?.runState == .running, "Delivery settled the running task")
        let cancelled = AgentHostInputQueuePayload(sessionId: "one", sequence: 3, inputs: [], recoveredInputs: [input])
        _ = reducer.receive(.sessionInputQueueChanged(cancelled), timestamp: "now")
        reducer.recoverInputs([input], sessionId: "one")
        try expect(reducer.records["one"]?.recoveredInputs == [input], "Cancelled input was lost or duplicated")
        reducer.apply(snapshot: snapshot, profile: .work, sessionDirectory: nil)
        try expect(reducer.records["one"]?.recoveredInputs == [input], "Snapshot repair erased recoverable input")
        reducer.removeRecoveredInput(input.id, sessionId: "one")
        try expect(reducer.records["one"]?.recoveredInputs.isEmpty == true, "Restored input was not removed")
        print("Running input native checks passed: default mode, queue decoding, images, delivery, run identity and cancellation recovery.")
    }
}
