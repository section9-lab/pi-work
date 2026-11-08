import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PiWork

@MainActor
final class TranscriptIntegrationTests: XCTestCase {
    @MainActor
    private struct Surface {
        let controller: NSHostingController<AnyView>
        let window: NSWindow
        var observer: TranscriptUserScrollObserverView? {
            @MainActor func find(_ view: NSView) -> TranscriptUserScrollObserverView? {
                if let value = view as? TranscriptUserScrollObserverView { return value }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return find(controller.view)
        }
        func close() {
            controller.rootView = AnyView(EmptyView()); controller.view.layoutSubtreeIfNeeded()
            window.contentViewController = nil; window.close()
        }
    }
    private func summary(_ id: String = "session-one") -> AgentHostSessionSummary {
        .init(id: id, path: "/tmp/\(id).jsonl", cwd: "/tmp/project", title: "Test", firstMessage: "",
              messageCount: 0, createdAt: "", modifiedAt: "")
    }
    private func snapshot(_ messages: [AgentHostSessionMessage] = [], id: String = "session-one", history: AgentHostSessionHistory? = nil) -> AgentHostSessionSnapshotResult {
        .init(session: .init(id: id, path: "/tmp/\(id).jsonl", cwd: "/tmp/project", title: "Test"),
              messages: messages, history: history, state: .idle, sequence: 0, turnId: nil, model: nil,
              thinkingLevel: .high, availableThinkingLevels: [.high], accessMode: .none, pendingApprovals: [])
    }
    private func user(_ id: String, _ text: String) -> AgentHostSessionMessage {
        .init(id: id, role: .user, content: [.text(text)], timestamp: "", provider: nil, model: nil,
              stopReason: nil, errorMessage: nil, toolCallId: nil, toolName: nil, isError: nil)
    }
    private func assistant(_ id: String, _ text: String) -> AgentHostSessionMessage {
        .init(id: id, role: .assistant, content: [.text(text)], timestamp: "", provider: nil, model: nil,
              stopReason: nil, errorMessage: nil, toolCallId: nil, toolName: nil, isError: nil)
    }
    private func text(_ sequence: Int, _ delta: String, turn: String = "live", generation: Int = 0,
                      part: Int = 0, session: String = "session-one", phase: AgentHostAssistantContentPhase = .delta) -> AgentHostServerEvent {
        .sessionAssistantContent(.init(sessionId: session, sequence: sequence, turnId: turn,
            generationIndex: generation, phase: phase, contentType: .text, contentIndex: part,
            delta: phase == .delta ? delta : nil, content: phase == .end ? delta : nil, toolCall: nil))
    }
    private func wait(_ description: String, timeout: Double = 5,
                      until condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard condition() else {
            XCTFail(description); throw NSError(domain: "TranscriptAcceptance", code: 1,
                userInfo: [NSLocalizedDescriptionKey: description])
        }
    }
    private func deliver(_ event: AgentHostServerEvent, sequence: Int, host: FakeAgentHost,
                         store: SessionStore, session: String = "session-one") async throws {
        await host.emit(event)
        try await wait("Store did not publish sequence \(sequence)") { store.records[session]?.lastSequence == sequence }
    }
    private func surface(_ store: SessionStore, width: CGFloat = 840, height: CGFloat = 640) -> Surface {
        let controller = NSHostingController(rootView: AnyView(ChatView(mode: .work, projects: [],
            selectedProject: .constant(PiProject(name: "Project", path: "/tmp/project")),
            sessionStore: store, composerDrafts: SessionComposerDraftStore(), onAddFolder: {})))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.orderFront(nil); controller.view.layoutSubtreeIfNeeded()
        return Surface(controller: controller, window: window)
    }
    private func keepTail(_ surface: Surface) {
        surface.controller.view.layoutSubtreeIfNeeded()
        guard let scroll = surface.observer?.enclosingScrollView, let document = scroll.documentView else { return }
        let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    func testConcurrentHistoryCallersShareTheRequestAndMergeExactlyOnce() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(snapshot([user("latest", "Latest")], history: .init(revision: "r", nextCursor: "page", hasMore: true)))
        await host.setTranscriptPage(.init(sessionId: "session-one", messages: [user("earlier", "Earlier")], revision: "r", nextCursor: nil, hasMore: false))
        await host.setTranscriptPageDelay(nanoseconds: 100_000_000)
        let store = SessionStore(service: host)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        let first = Task { try await store.loadEarlierMessages(sessionId: "session-one") }
        let second = Task { try await store.loadEarlierMessages(sessionId: "session-one") }
        let counts = try await [first.value, second.value]
        XCTAssertEqual(counts, [1, 1])
        let requests = await host.transcriptPageCount; XCTAssertEqual(requests, 1)
        XCTAssertEqual(store.records["session-one"]?.transcript.map(\.id), ["earlier", "latest"])
        await store.stop()
    }

    func testStopCancelsPendingHistoryWithoutMergingAfterShutdown() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(snapshot([user("latest", "Latest")], history: .init(revision: "r", nextCursor: "page", hasMore: true)))
        await host.setTranscriptPage(.init(sessionId: "session-one", messages: [user("earlier", "Earlier")], revision: "r", nextCursor: nil, hasMore: false))
        await host.setTranscriptPageDelay(nanoseconds: 1_000_000_000)
        let store = SessionStore(service: host)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        let load = Task { try await store.loadEarlierMessages(sessionId: "session-one") }
        let deadline = Date().addingTimeInterval(5)
        while await host.transcriptPageCount == 0, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        let requests = await host.transcriptPageCount; XCTAssertEqual(requests, 1)
        await store.stop()
        switch await load.result {
        case .success: XCTFail("A stopped Store must reject the outstanding page")
        case .failure: break
        }
        XCTAssertEqual(store.records["session-one"]?.transcript.map(\.id), ["latest"])
    }

    func testRemotePrefetchPreservesWindowWhileCoveringTwoPages() async throws {
        func messages(_ range: Range<Int>) -> [AgentHostSessionMessage] { range.map { user("row-\($0)", "History \($0)") } }
        let host = FakeAgentHost()
        await host.setSnapshot(snapshot(messages(900..<1000), history: .init(revision: "r", nextCursor: "one", hasMore: true)))
        await host.setTranscriptPagesByCursor([
            "one": .init(sessionId: "session-one", messages: messages(800..<900), revision: "r", nextCursor: "two", hasMore: true),
            "two": .init(sessionId: "session-one", messages: messages(700..<800), revision: "r", nextCursor: nil, hasMore: false)
        ])
        let store = SessionStore(service: host)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        let view = surface(store); defer { view.close() }
        func first() -> Int? {
            view.observer?.viewport?.frames.keys.compactMap { Int($0.replacingOccurrences(of: "row-", with: "")) }.min()
        }
        let initialFirst = 900 + 100 - TranscriptWindowNavigation.maximumCount
        try await wait("Initial window did not mount") {
            first() == initialFirst
                && view.observer?.viewport?.frames.count == TranscriptWindowNavigation.maximumCount
        }

        var previousFirst = initialFirst
        var moves = 0
        while (store.records["session-one"]?.transcript.count ?? 0) < 300, moves < 6 {
            let observer = try XCTUnwrap(view.observer)
            let scroll = try XCTUnwrap(observer.enclosingScrollView)
            let doc = try XCTUnwrap(scroll.documentView)
            let revision = observer.historyLoadRevision
            observer.onUserScroll()
            scroll.contentView.scroll(to: CGPoint(
                x: 0,
                y: doc.isFlipped
                    ? doc.bounds.minY
                    : max(doc.bounds.minY, doc.bounds.maxY - scroll.contentView.bounds.height)
            ))
            scroll.reflectScrolledClipView(scroll.contentView)
            observer.onReachTop()
            try await wait("History did not move earlier", timeout: 10) {
                view.controller.view.layoutSubtreeIfNeeded()
                return observer.historyLoadRevision > revision && (first() ?? Int.max) < previousFirst
            }
            previousFirst = first() ?? previousFirst
            moves += 1
            XCTAssertEqual(observer.viewport?.frames.count, TranscriptWindowNavigation.maximumCount)
        }

        let requests = await host.transcriptPageCount
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(store.records["session-one"]?.transcript.count, 300)
        XCTAssertLessThan(previousFirst, 900, "Both pages must be covered while staying in history")
        await store.stop()
    }

    func testPublicationSeparatesOnlyExistingExactTextDestinationAndAlwaysFlushesTerminalState() async throws {
        let host = FakeAgentHost(); await host.setSnapshot(snapshot())
        let store = SessionStore(service: host, streamingPublishDelayNanoseconds: 1_000_000)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        var packets: [Int: SessionTranscriptUpdate] = [:]
        let observation = store.transcriptUpdates.sink { update in
            if let sequence = store.records["session-one"]?.lastSequence { packets[sequence] = update }
        }
        try await deliver(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "live", state: .running)), sequence: 1, host: host, store: store)
        try await deliver(text(2, "First"), sequence: 2, host: host, store: store)
        let structuralRevision = store.transcriptStructureRevision(sessionID: "session-one")
        try await deliver(text(3, " next"), sequence: 3, host: host, store: store)
        XCTAssertEqual(packets[2]?.structuralSessionIDs, ["session-one"])
        XCTAssertEqual(packets[3]?.contentMessageIDs["session-one"], ["turn:live:assistant:0"])
        XCTAssertEqual(store.transcriptStructureRevision(sessionID: "session-one"), structuralRevision)
        try await deliver(text(4, "second block", part: 1), sequence: 4, host: host, store: store)
        XCTAssertEqual(packets[4]?.structuralSessionIDs, ["session-one"])
        await host.emit(text(5, " FINAL", part: 1))
        try await deliver(.sessionStateChanged(.init(sessionId: "session-one", sequence: 6, turnId: "live", state: .idle)), sequence: 6, host: host, store: store)
        XCTAssertEqual(packets[6]?.structuralSessionIDs, ["session-one"])
        XCTAssertTrue(PiChatMessage(message: store.records["session-one"]!.transcript.last!).text.hasSuffix(" FINAL"))
        // An ignored Int.min sequence must neither overflow nor taint the next batch.
        await host.emit(text(Int.min, "ignored"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(store.records["session-one"]?.lastSequence, 6)
        observation.cancel(); await store.stop()
    }

    func testLateGenerationAndMixedProtocolNeverRouteToTheWrongLocalRow() async throws {
        let host = FakeAgentHost(); await host.setSnapshot(snapshot())
        let store = SessionStore(service: host, streamingPublishDelayNanoseconds: 1_000_000)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        try await deliver(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "live", state: .running)), sequence: 1, host: host, store: store)
        try await deliver(text(2, "generation zero"), sequence: 2, host: host, store: store)
        let model = TranscriptMessagePresentation()
        let zero = PiChatMessage(message: store.records["session-one"]!.transcript.last!, isStreaming: true)
        model.configure(fallback: zero, store: store, sessionID: "session-one", isGrouped: false)
        try await deliver(text(3, "generation one", generation: 1), sequence: 3, host: host, store: store)
        try await deliver(text(4, " late", generation: 0), sequence: 4, host: host, store: store)
        XCTAssertEqual(store.latestTranscriptUpdate.structuralSessionIDs, ["session-one"])
        let cache = TranscriptPresentationCache()
        let window = cache.project(record: store.records["session-one"]!,
            structuralRevision: store.transcriptStructureRevision(sessionID: "session-one"), navigation: .init(), limit: 100)
        let freshZero = try XCTUnwrap(window.messages.first { $0.id == zero.id })
        model.configure(fallback: freshZero, store: store, sessionID: "session-one", isGrouped: false)
        XCTAssertEqual(model.message?.text, "generation zero late")
        XCTAssertEqual(model.message?.isStreaming, false)
        XCTAssertEqual(window.messages.last?.text, "generation one")
        try await deliver(.sessionMessageDelta(.init(sessionId: "session-one", sequence: 5, turnId: "live", delta: "generic")), sequence: 5, host: host, store: store)
        XCTAssertEqual(store.latestTranscriptUpdate.structuralSessionIDs, ["session-one"])
        try await deliver(text(6, " older", generation: 1), sequence: 6, host: host, store: store)
        XCTAssertEqual(store.latestTranscriptUpdate.structuralSessionIDs, ["session-one"])
        XCTAssertEqual(store.records["session-one"]?.transcript.last?.id, "turn:live:assistant")
        model.stop(); await store.stop()
    }

    func testLocalPresentationReceivesFinalTextWithoutAnotherParentSnapshot() async throws {
        for fails in [false, true] {
            let host = FakeAgentHost(); await host.setSnapshot(snapshot())
            let store = SessionStore(service: host, streamingPublishDelayNanoseconds: 1_000_000)
            try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
            try await deliver(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "live", state: .running)), sequence: 1, host: host, store: store)
            try await deliver(text(2, "prefix"), sequence: 2, host: host, store: store)
            let stale = PiChatMessage(message: store.records["session-one"]!.transcript.last!, isStreaming: true)
            let model = TranscriptMessagePresentation()
            model.configure(fallback: stale, store: store, sessionID: "session-one", isGrouped: false)
            let renderer = AssistantMarkdownPresentation(text: "prefix", delayNanoseconds: 5_000_000_000)
            renderer.connect(to: model, blockID: stale.parts[0].id)
            await host.emit(text(3, " COMPLETE"))
            let terminal: AgentHostServerEvent = fails
                ? .sessionError(.init(sessionId: "session-one", sequence: 4, turnId: "live", code: "test", message: "test failure"))
                : .sessionStateChanged(.init(sessionId: "session-one", sequence: 4, turnId: "live", state: .idle))
            try await deliver(terminal, sequence: 4, host: host, store: store)
            XCTAssertEqual(model.message?.text, "prefix COMPLETE")
            XCTAssertEqual(model.message?.isStreaming, false)
            XCTAssertEqual(renderer.renderedText, "prefix COMPLETE", "Terminal delivery must bypass a stale parent onChange")
            renderer.disconnect(); renderer.cancel()
            XCTAssertEqual(store.records["session-one"]?.runState, fails ? .failed : .idle)
            model.stop()
            // Reappearance must not roll back to the old cached parent prefix.
            model.configure(fallback: stale, store: store, sessionID: "session-one", isGrouped: false)
            XCTAssertEqual(model.message?.text, "prefix COMPLETE")
            XCTAssertEqual(model.message?.isStreaming, false)
            model.stop(); await store.stop()
        }
    }

    func testGroupedRowsNeverLoseOtherToolsWhenAFormerLiveRowIsReused() async throws {
        let host = FakeAgentHost(); await host.setSnapshot(snapshot())
        let store = SessionStore(service: host, streamingPublishDelayNanoseconds: 1_000_000)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        try await deliver(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "live", state: .running)), sequence: 1, host: host, store: store)
        try await deliver(text(2, "text"), sequence: 2, host: host, store: store)
        let model = TranscriptMessagePresentation()
        model.configure(fallback: PiChatMessage(message: store.records["session-one"]!.transcript.last!, isStreaming: true), store: store, sessionID: "session-one", isGrouped: false)
        let tools = ["a", "b"].map { SessionTranscriptPart.tool(SessionToolRecord(id: $0, name: "bash", summary: $0, state: .running, isError: nil)) }
        let grouped = PiChatMessage(id: "turn:live:assistant:0", role: .assistant, parts: tools, timestamp: nil, isStreaming: true)
        model.configure(fallback: grouped, store: store, sessionID: "session-one", isGrouped: true)
        XCTAssertEqual(model.message?.parts, tools, "The complete grouped snapshot must be authoritative, not its first raw source")
        let renderer = AssistantMarkdownPresentation(text: "", delayNanoseconds: 5_000_000_000)
        renderer.connect(to: model, blockID: "leading")
        let completed = PiChatMessage(id: grouped.id, role: .assistant,
            parts: [.text(id: "leading", text: "Complete leading text")] + tools, timestamp: nil, isStreaming: false)
        model.configure(fallback: completed, store: store, sessionID: "session-one", isGrouped: true)
        XCTAssertEqual(renderer.renderedText, "Complete leading text")
        XCTAssertEqual(model.message?.parts, completed.parts)
        renderer.disconnect(); renderer.cancel()
        await store.stop()
    }

    func testTaggedThinkingUsesTheResponseBlockAndCopiesTheCompleteResponse() async throws {
        let host = FakeAgentHost(); await host.setSnapshot(snapshot())
        let store = SessionStore(service: host, streamingPublishDelayNanoseconds: 1_000_000)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        try await deliver(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "live", state: .running)), sequence: 1, host: host, store: store)
        try await deliver(text(2, "<think>Reasoning</think>\n\n# Visible\nFirst"), sequence: 2, host: host, store: store)
        let fallback = PiChatMessage(message: store.records["session-one"]!.transcript.last!, isStreaming: true)
        let model = TranscriptMessagePresentation()
        model.configure(fallback: fallback, store: store, sessionID: "session-one", isGrouped: false)
        let renderer = AssistantMarkdownPresentation(text: "", delayNanoseconds: 5_000_000_000)
        renderer.connect(to: model, blockID: fallback.parts[0].id + ":response")
        await host.emit(text(3, "\nFINAL"))
        try await deliver(.sessionStateChanged(.init(sessionId: "session-one", sequence: 4, turnId: "live", state: .idle)), sequence: 4, host: host, store: store)
        XCTAssertEqual(renderer.renderedText, "# Visible\nFirst\nFINAL")
        XCTAssertEqual(model.message?.copyableText, renderer.renderedText)
        renderer.disconnect(); renderer.cancel(); model.stop(); await store.stop()
    }

    func testStopCancelsPendingPublicationAndPreservesTheLatestLocalText() async throws {
        let host = FakeAgentHost(); await host.setSnapshot(snapshot())
        let store = SessionStore(service: host, streamingPublishDelayNanoseconds: 50_000_000)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        try await deliver(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "live", state: .running)), sequence: 1, host: host, store: store)
        try await deliver(text(2, "prefix"), sequence: 2, host: host, store: store)
        let model = TranscriptMessagePresentation()
        model.configure(fallback: PiChatMessage(message: store.records["session-one"]!.transcript.last!, isStreaming: true), store: store, sessionID: "session-one", isGrouped: false)
        await host.emit(text(3, " tail"))
        try await Task.sleep(nanoseconds: 10_000_000) // Consume the event before the 50 ms publication window.
        await store.stop()
        XCTAssertEqual(store.records["session-one"]?.lastSequence, 3)
        XCTAssertEqual(model.message?.text, "prefix tail")
        XCTAssertEqual(model.message?.isStreaming, false)
        model.stop()
    }

    func testComplexStreamingReachesActualMarkdownPresentation() async throws {
        #if DEBUG || TRANSCRIPT_ACCEPTANCE
        let checkpoint = AssistantMarkdownDiagnostics.checkpoint
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/markdown/performance-complex.md")
        let template = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "{{TITLE}}", with: "Acceptance")
            .replacingOccurrences(of: "{{INDEX}}", with: "1000")
            .replacingOccurrences(of: "{{SALT}}", with: "acceptance")
        let marker = "TRANSCRIPT-FINAL-VISIBLE-ACCEPTANCE"
        let body = template + "\n\n" + template + "\n\n" + marker + "\n"
        let host = FakeAgentHost(); await host.setSnapshot(snapshot((0..<3).map { user("row-\($0)", "Question \($0)") }))
        let store = SessionStore(service: host)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        let view = surface(store); defer { view.close() }
        try await wait("Initial conversation did not mount") { view.controller.view.layoutSubtreeIfNeeded(); return view.observer != nil }
        let chars = Array(body), size = (chars.count + 149) / 150
        let chunks = stride(from: 0, to: chars.count, by: size).map { String(chars[$0..<min($0 + size, chars.count)]) }
        await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "live", state: .running)))
        let producer = Task.detached {
            for (index, chunk) in chunks.enumerated() {
                await host.emit(.sessionAssistantContent(.init(sessionId: "session-one", sequence: index + 2,
                    turnId: "live", generationIndex: 0, phase: .delta, contentType: .text, contentIndex: 0,
                    delta: chunk, content: nil, toolCall: nil)))
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: chunks.count + 2, turnId: "live", state: .idle)))
        }
        let until = Date().addingTimeInterval(8)
        while Date() < until, store.records["session-one"]?.lastSequence != chunks.count + 2 {
            keepTail(view); try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await producer.value
        try await wait("Completion event was not published", timeout: 15) { store.records["session-one"]?.lastSequence == chunks.count + 2 }
        XCTAssertEqual(PiChatMessage(message: store.records["session-one"]!.transcript.last!).text, body)
        try await wait("The actual Markdown presentation never received the complete final document", timeout: 15) {
            keepTail(view); return AssistantMarkdownDiagnostics.hasRendered(body, after: checkpoint)
        }
        XCTAssertLessThanOrEqual(view.observer?.viewport?.frames.count ?? 0, 100)
        let repairs = await host.snapshotCount; XCTAssertEqual(repairs, 1)
        await store.stop()
        #else
        throw XCTSkip("Run Release acceptance with -DTRANSCRIPT_ACCEPTANCE to inspect actual renderer models")
        #endif
    }

    func testSessionSwapWithSameMessageIDsDoesNotShowOldContentOrAcceptOldDelivery() async throws {
        #if DEBUG || TRANSCRIPT_ACCEPTANCE
        let checkpoint = AssistantMarkdownDiagnostics.checkpoint
        let host = FakeAgentHost()
        await host.setSnapshot(snapshot([assistant("shared-id", "SESSION-ONE-MARKER")]))
        let store = SessionStore(service: host)
        try await store.openSession(summary(), profile: .work, sessionDirectory: nil)
        let view = surface(store); defer { view.close() }
        try await wait("First session never appeared") { view.controller.view.layoutSubtreeIfNeeded(); return AssistantMarkdownDiagnostics.hasRendered("SESSION-ONE-MARKER", after: checkpoint) }
        await host.setSnapshot(snapshot([assistant("shared-id", "SESSION-TWO-MARKER")], id: "session-two"))
        try await store.openSession(summary("session-two"), profile: .work, sessionDirectory: nil)
        try await wait("Second session never appeared") { view.controller.view.layoutSubtreeIfNeeded(); return AssistantMarkdownDiagnostics.hasRendered("SESSION-TWO-MARKER", after: checkpoint) }
        await host.emit(text(1, "OLD-SESSION-LATE", session: "session-one"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(AssistantMarkdownDiagnostics.hasRendered("OLD-SESSION-LATE", after: checkpoint))
        let returnCheckpoint = AssistantMarkdownDiagnostics.checkpoint
        for id in ["session-one", "session-two", "session-one"] {
            try store.selectOpenSession(sessionId: id, profile: .work, cwd: "/tmp/project")
        }
        try await wait("Rapid session swap left the transcript masked", timeout: 8) {
            view.controller.view.layoutSubtreeIfNeeded(); return AssistantMarkdownDiagnostics.hasRendered("SESSION-ONE-MARKER", after: returnCheckpoint)
        }
        await store.stop()
        #else
        throw XCTSkip("Run Release acceptance with -DTRANSCRIPT_ACCEPTANCE to inspect actual renderer models")
        #endif
    }
}
