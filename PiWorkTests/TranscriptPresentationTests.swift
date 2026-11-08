import AppKit
import Combine
import XCTest
@testable import PiWork

@MainActor
final class TranscriptPresentationTests: XCTestCase {
    private func record(_ count: Int = 1000) -> SessionRecord {
        var value = SessionStoreReducer.project(summary: AgentHostSessionSummary(
            id: "presentation", path: "/tmp/presentation.jsonl", cwd: "/tmp/project", title: "Test",
            firstMessage: "", messageCount: count, createdAt: "", modifiedAt: ""),
            profile: .work, sessionDirectory: nil)
        value.transcript = (0..<count).map { index in
            SessionTranscriptMessage(id: "row-\(index)", role: .assistant,
                parts: [.text(id: "part-\(index)", text: "Reply \(index)")], timestamp: "")
        }
        return value
    }

    func testCacheKeepsTheBoundedWindowAndMovesWithoutGrowing() {
        let cache = TranscriptPresentationCache()
        let value = record()
        var navigation = TranscriptWindowNavigation()
        var seen: Set<String> = []
        while true {
            let window = cache.project(record: value, structuralRevision: 1, navigation: navigation, limit: TranscriptWindow.batchSize)
            XCTAssertEqual(window.messages.count, TranscriptWindow.batchSize)
            XCTAssertEqual(window.sourceRange.count, TranscriptWindow.batchSize)
            seen.formUnion(window.messages.map(\.id))
            if window.sourceRange.lowerBound == 0 { break }
            navigation.revealEarlier(in: window.sourceIDs)
        }
        XCTAssertEqual(seen.count, 1000, "Bounded windows must not make intermediate messages unreachable")
    }

    func testContentDoesNotRescanMembershipButStructuralRevisionRefreshesIt() {
        let cache = TranscriptPresentationCache()
        var value = record(4)
        let navigation = TranscriptWindowNavigation()
        let before = cache.project(record: value, structuralRevision: 1, navigation: navigation, limit: TranscriptWindow.batchSize)
        value.transcript[3].parts = [.text(id: "part-3", text: "Updated content")]
        let contentOnly = cache.project(record: value, structuralRevision: 1, navigation: navigation, limit: TranscriptWindow.batchSize)
        XCTAssertEqual(contentOnly.messages, before.messages, "Local row delivery owns a content-only revision")
        let structural = cache.project(record: value, structuralRevision: 2, navigation: navigation, limit: TranscriptWindow.batchSize)
        XCTAssertEqual(structural.messages.last?.text, "Updated content")
        value.transcript.removeFirst()
        let changedCount = cache.project(record: value, structuralRevision: 2, navigation: navigation, limit: TranscriptWindow.batchSize)
        XCTAssertEqual(changedCount.messages.count, 3)
    }

    func testInvalidationPublishesAndClearReleasesCachedSnapshotsWithoutPublishing() {
        let cache = TranscriptPresentationCache()
        var value = record(2)
        var notifications = 0
        let subscription = cache.objectWillChange.sink { notifications += 1 }
        _ = cache.project(record: value, structuralRevision: 1, navigation: .init(), limit: 100)
        cache.invalidate()
        XCTAssertEqual(notifications, 1)
        _ = cache.project(record: value, structuralRevision: 1, navigation: .init(), limit: 100)
        cache.clear()
        XCTAssertEqual(notifications, 1)
        value.transcript[1].parts = [.text(id: "part-1", text: "Fresh after reappearance")]
        XCTAssertEqual(cache.project(record: value, structuralRevision: 1, navigation: .init(), limit: 100).messages.last?.text,
                       "Fresh after reappearance")
        subscription.cancel()
    }

    func testSourceIdentityAndRevisionProtectEqualLengthSessionSwapsAndSnapshots() {
        let cache = TranscriptPresentationCache()
        var a = record(2)
        let one = cache.project(record: a, structuralRevision: 1, navigation: .init(), limit: 100)
        a.descriptor = AgentHostSessionDescriptor(id: "other", path: "/tmp/other", cwd: "/tmp/project", title: "Other")
        a.transcript[0].parts = [.text(id: "other-part", text: "Other session")]
        let two = cache.project(record: a, structuralRevision: 1, navigation: .init(), limit: 100)
        XCTAssertNotEqual(one.messages, two.messages)
        // Keep the same count and IDs: revision must still invalidate.
        a.transcript[0].parts = [.text(id: "new-part", text: "Repaired snapshot")]
        XCTAssertEqual(cache.project(record: a, structuralRevision: 2, navigation: .init(), limit: 100).messages.first?.text,
                       "Repaired snapshot")
    }

    func testToolGroupingRetainsSourceSpansAndPartIdentity() {
        let cache = TranscriptPresentationCache()
        var value = record(4)
        let first = SessionToolRecord(id: "one", name: "bash", summary: "first", state: .running, isError: nil)
        let second = SessionToolRecord(id: "two", name: "bash", summary: "second", state: .running, isError: nil)
        value.transcript[1].parts = [.tool(first)]
        value.transcript[2].parts = [.tool(second)]
        let window = cache.project(record: value, structuralRevision: 1, navigation: .init(), limit: 100)
        XCTAssertEqual(window.messages.count, 3)
        XCTAssertEqual(window.sourceRange.count, 4)
        XCTAssertEqual(window.sourceSpans["row-1"], TranscriptRowSourceSpan(firstID: "row-1", lastID: "row-2"))
        XCTAssertEqual(window.sourceMessageIDsByPartID["tool:two"], "row-2")
        XCTAssertEqual(window.messages[1].parts, [.tool(first), .tool(second)])
    }

    func testVisibilityAndStreamingIdentityAreRefreshedOnTerminalTransition() {
        let cache = TranscriptPresentationCache()
        var value = record(1)
        value.runState = .running; value.activeTurnId = "live"
        value.transcript = [SessionTranscriptMessage(id: "turn:live:assistant:0", role: .assistant,
            parts: [.text(id: "part", text: " ")], timestamp: "")]
        let live = cache.project(record: value, structuralRevision: 1, navigation: .init(), limit: 100)
        XCTAssertEqual(live.messages.count, 1)
        XCTAssertEqual(live.messages.first?.isStreaming, true)
        value.runState = .idle; value.activeTurnId = nil
        let idle = cache.project(record: value, structuralRevision: 2, navigation: .init(), limit: 100)
        XCTAssertTrue(idle.messages.isEmpty, "An empty completed placeholder must not remain visible")
    }

    func testTextIdentityRejectsOldGenerationNewBlocksAndMixedProtocol() {
        var value = record(0)
        value.runState = .running; value.activeTurnId = "turn"; value.lastSequence = 8
        value.transcript = [SessionTranscriptMessage(id: "turn:turn:assistant:1", role: .assistant,
            parts: [.text(id: "turn:turn:assistant:1:content:1:0", text: "current")], timestamp: "")]
        func identity(_ generation: Int, _ content: Int = 0) -> SessionTextUpdateIdentity {
            SessionTextUpdateIdentity(.sessionAssistantContent(.init(sessionId: "presentation", sequence: 9,
                turnId: "turn", generationIndex: generation, phase: .delta, contentType: .text,
                contentIndex: content, delta: "next", content: nil, toolCall: nil)))!
        }
        XCTAssertTrue(identity(1).matches(value, sequence: 8))
        XCTAssertFalse(identity(0).matches(value, sequence: 8), "A late generation must take the structural path")
        XCTAssertFalse(identity(1, 1).matches(value, sequence: 8))
        let generic = SessionTextUpdateIdentity(.sessionMessageDelta(.init(sessionId: "presentation", sequence: 9, turnId: "turn", delta: "next")))!
        XCTAssertFalse(generic.matches(value, sequence: 8))
        value.transcript[0].parts.append(.text(id: "extra", text: "block"))
        XCTAssertFalse(identity(1).matches(value, sequence: 8))
    }

    func testRetainedToolControlsKeepIdentityWhenGroupFirstSourceChanges() {
        let state = TranscriptToolExpansionState()
        let a = SessionToolRecord(id: "a", name: "bash", summary: "", state: .completed, isError: nil)
        let b = SessionToolRecord(id: "b", name: "bash", summary: "", state: .completed, isError: nil)
        let c = SessionToolRecord(id: "c", name: "bash", summary: "", state: .completed, isError: nil)
        func row(_ id: String, _ tools: [SessionToolRecord]) -> PiChatMessage {
            .init(id: id, role: .assistant, parts: tools.map { .tool($0) }, timestamp: nil, isStreaming: false)
        }
        let original = state.rows(for: [row("source-b", [b, c])])[0].id
        XCTAssertEqual(state.rows(for: [row("source-a", [a, b, c])])[0].id, original)
        XCTAssertEqual(state.rows(for: [row("source-c", [c])])[0].id, original)
        XCTAssertEqual(state.groupIdentity(for: [a, b]), state.groupIdentity(for: [b, c]))
        XCTAssertEqual(Set(state.rows(for: [row("one", [a]), row("two", [a])]).map(\.id)).count, 2)
    }

    func testDocumentFramesTrackScrollBeforeAnotherSwiftUILayout() throws {
        final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scroll.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        scroll.layoutSubtreeIfNeeded()
        let viewport = TranscriptViewport(); viewport.scrollView = scroll
        viewport.frames = ["row": CGRect(x: 0, y: 1000, width: 400, height: 100)]
        XCTAssertFalse(viewport.hasFrames(forExactly: ["row", "new-row"]), "Old preferences cannot authorize anchor correction for the new window")
        XCTAssertTrue(viewport.hasFrames(forExactly: ["row"]))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        XCTAssertEqual(try XCTUnwrap(viewport.currentFrame(for: "row")).minY, 200, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(viewport.frames["row"]).minY, 200, accuracy: 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        XCTAssertEqual(try XCTUnwrap(viewport.frames["row"]).minY, 100, accuracy: 1)
        viewport.restoreOffset(59, for: "row")
        XCTAssertEqual(try XCTUnwrap(viewport.currentFrame(for: "row")).minY, 59, accuracy: 1)
    }

    func testManualToolPreferencesSurviveGroupMergesAndRemainSessionScoped() {
        let state = TranscriptToolExpansionState()
        let a = SessionToolRecord(id: "a", name: "bash", summary: "", state: .completed, isError: nil)
        let b = SessionToolRecord(id: "b", name: "bash", summary: "", state: .completed, isError: nil)
        state.set(true, for: [a]); state.setDetail(true, for: "a")
        XCTAssertEqual(state.selection(for: [b, a]), true)
        XCTAssertEqual(state.detailSelection(for: "a"), true)
        state.set(false, for: [b])
        XCTAssertEqual(state.selection(for: [a, b]), false, "Latest explicit selection wins a merged group")
        state.reset()
        XCTAssertNil(state.selection(for: [a, b])); XCTAssertNil(state.detailSelection(for: "a"))
    }
}
