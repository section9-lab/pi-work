import XCTest
@testable import PiWork

final class CompactionTests: XCTestCase {
    private func snapshot(messages: [AgentHostSessionMessage] = [], compaction: AgentHostCompaction? = nil) -> AgentHostSessionSnapshotResult {
        AgentHostSessionSnapshotResult(
            session: AgentHostSessionDescriptor(id: "session", path: "/tmp/session.jsonl", cwd: "/tmp", title: "Work"),
            messages: messages, state: compaction == nil ? .idle : .running, sequence: 0,
            turnId: nil, model: nil, thinkingLevel: .off, availableThinkingLevels: [.off],
            accessMode: .full, pendingApprovals: [], compaction: compaction)
    }

    private func outcome(_ status: AgentHostCompaction.Status = .completed) -> AgentHostCompaction {
        AgentHostCompaction(id: "entry", status: status, reason: .threshold,
            timestamp: "2026-11-03T12:00:00.000Z", summary: status == .completed ? "## Goal\nContinue" : nil,
            tokensBefore: 148_000, estimatedTokensAfter: 32_000)
    }

    private func event(_ compaction: AgentHostCompaction, sequence: Int) -> AgentHostServerEvent {
        .sessionCompactionChanged(AgentHostCompactionChangedPayload(sessionId: "session", sequence: sequence,
            compaction: compaction, contextUsage: AgentHostContextUsage(tokens: 32_000, contextWindow: 200_000, percent: 16)))
    }

    func testDecodesPrivateACPLifecycleAndOptionalMetadata() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"_piWork/session.compactionChanged","params":{"sessionId":"session","sequence":7,"compaction":{"id":"entry","status":"running","reason":"overflow","timestamp":"now"}}}"#.utf8)
        guard case .sessionCompactionChanged(let payload) = try AgentHostServerEvent.decode(from: data) else {
            return XCTFail("Expected compaction event")
        }
        XCTAssertEqual(payload.sequence, 7)
        XCTAssertEqual(payload.compaction.reason, .overflow)
        XCTAssertNil(payload.compaction.estimatedTokensAfter)
        XCTAssertNil(payload.contextUsage)
    }

    func testSnapshotRestoresRunningCompactionWhenSwitchingSessions() {
        let compaction = outcome(.running)
        let record = SessionStoreReducer.project(snapshot: snapshot(compaction: compaction), profile: .work, sessionDirectory: nil)
        XCTAssertEqual(record.compaction, compaction)
        XCTAssertEqual(record.runState, .running)
        XCTAssertTrue(record.transcript.isEmpty)
    }

    func testCompletionAddsOneVisibleRecordWithoutSettlingActiveRun() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(snapshot: snapshot(), profile: .work, sessionDirectory: nil)
        _ = reducer.submitPrompt(sessionId: "session", turnId: "turn", text: "Continue", timestamp: "now")
        _ = reducer.receive(event(outcome(.running), sequence: 1), timestamp: "now")
        XCTAssertNotNil(reducer.records["session"]?.compaction)
        let completed = event(outcome(), sequence: 2)
        _ = reducer.receive(completed, timestamp: "now")
        _ = reducer.receive(completed, timestamp: "now")
        _ = reducer.receive(event(outcome(), sequence: 3), timestamp: "now")
        let record = try XCTUnwrap(reducer.records["session"])
        XCTAssertNil(record.compaction)
        XCTAssertEqual(record.activeTurnId, "turn")
        XCTAssertEqual(record.transcript.filter { $0.compaction != nil }.count, 1)
        XCTAssertEqual(record.contextUsage?.tokens, 32_000)
        XCTAssertTrue(PiChatMessage(message: try XCTUnwrap(record.transcript.last)).isVisible)
    }

    func testCompactionFailureDoesNotMarkEntireConversationFailed() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(snapshot: snapshot(), profile: .work, sessionDirectory: nil)
        var failed = outcome(.failed)
        failed.errorMessage = "Summary unavailable"
        _ = reducer.receive(event(failed, sequence: 1), timestamp: "now")
        XCTAssertEqual(reducer.records["session"]?.runState, .idle)
        XCTAssertNil(reducer.records["session"]?.errorMessage)
        XCTAssertEqual(reducer.records["session"]?.transcript.last?.compaction?.errorMessage, "Summary unavailable")
    }

    func testMissingSequenceRequestsRepairInsteadOfInventingSuccess() {
        var reducer = SessionStoreReducer()
        reducer.apply(snapshot: snapshot(), profile: .work, sessionDirectory: nil)
        XCTAssertEqual(reducer.receive(event(outcome(), sequence: 3), timestamp: "now"), [.requestSnapshot(sessionId: "session")])
        XCTAssertTrue(reducer.records["session"]!.transcript.isEmpty)
    }

    func testHistoryProjectionAndPaginationKeepCompactionIdentity() throws {
        var message = AgentHostSessionMessage(id: "entry", role: .system, content: [], timestamp: "now",
            provider: nil, model: nil, stopReason: nil, errorMessage: nil, toolCallId: nil, toolName: nil, isError: nil)
        message.compaction = outcome()
        var reducer = SessionStoreReducer()
        reducer.apply(snapshot: snapshot(messages: [message]), profile: .work, sessionDirectory: nil)
        let transcript = try XCTUnwrap(reducer.records["session"]?.transcript.first)
        XCTAssertEqual(PiChatMessage(message: transcript).compaction, outcome())
        XCTAssertTrue(PiChatMessage(message: message).isVisible)
        XCTAssertEqual(reducer.prependTranscriptPage(AgentHostSessionTranscriptPageResult(sessionId: "session",
            messages: [message], revision: "r1", nextCursor: nil, hasMore: false)), 0)
        XCTAssertEqual(reducer.records["session"]?.transcript.count, 1)
    }

    func testTokenDisplayDoesNotInventAnAfterCount() {
        var compaction = outcome()
        let text = CompactionPresentation.tokenText(compaction)
        XCTAssertNotNil(text)
        compaction.estimatedTokensAfter = nil
        XCTAssertNotEqual(text, CompactionPresentation.tokenText(compaction))
        XCTAssertEqual(CompactionPresentation.activityKey(.overflow), "chat.compaction.running.overflow")
        XCTAssertEqual(CompactionPresentation.titleKey(.cancelled), "chat.compaction.cancelled")
    }

    func testCompactCommandUsesAnExactWhitespaceBoundary() {
        XCTAssertEqual(CompactionPresentation.instructions(in: "/compact"), "")
        XCTAssertEqual(CompactionPresentation.instructions(in: "/compact\t保留设计决策"), "保留设计决策")
        XCTAssertNil(CompactionPresentation.instructions(in: "/compact-other"))
        XCTAssertNil(CompactionPresentation.instructions(in: "Please /compact"))
    }

    func testUsageKeepsUnknownPostCompactionCountInsteadOfInventingZero() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session","update":{"sessionUpdate":"usage_update","used":0,"size":200000,"cost":{"amount":1.258,"currency":"USD"},"_meta":{"sequence":1,"piWork":{"contextUsage":{"tokens":null,"contextWindow":200000,"percent":null},"costSource":"estimated"}}}}}"#.utf8)
        let event = try AgentHostServerEvent.decode(from: data)
        var reducer = SessionStoreReducer()
        reducer.apply(snapshot: snapshot(), profile: .work, sessionDirectory: nil)
        _ = reducer.receive(event, timestamp: "now")
        XCTAssertNil(reducer.records["session"]?.contextUsage?.tokens)
        XCTAssertNil(reducer.records["session"]?.contextUsage?.percent)
        XCTAssertEqual(reducer.records["session"]?.acpState.cost?.amount, 1.258)
    }

    func testOlderSnapshotWithoutCompactionStillDecodes() throws {
        let data = Data(#"{"session":{"id":"session","path":"","cwd":"/tmp","title":"Work"},"messages":[],"state":"idle","sequence":0,"turnId":null,"model":null,"thinkingLevel":"off","availableThinkingLevels":["off"],"modelOptions":{"fastMode":{"supported":false,"enabled":false},"oneMillionContext":{"supported":false,"enabled":false}},"accessMode":"full","pendingApprovals":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentHostSessionSnapshotResult.self, from: data).compaction)
    }
}
