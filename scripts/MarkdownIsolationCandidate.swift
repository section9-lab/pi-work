// EXPERIMENT ONLY. Copied into the isolated benchmark app, never the production target.
import Combine
import SwiftUI

// Both variants execute the SAME Release binary. Flags are read once per process.
enum MarkdownIsolationConfiguration {
    static let variant = ProcessInfo.processInfo.environment["PERF_VARIANT"] ?? "baseline"
    static let fixedWindow = variant == "combined" || variant == "fixed"
    static let isolateText = variant == "combined" || variant == "isolated"
    static let shift = 60
}

@MainActor
enum MarkdownIsolationProbe {
    static var projections = 0
    static var sourceRows = 0
    static var localDeliveries = 0
    static var skippedParentEvents = 0
    static var markdownPublishes = 0
    static var markdownInitializations = 0
    static var lastMarkdownText = ""
    private final class WeakPresentation {
        weak var value: AssistantMarkdownPresentation?
        init(_ value: AssistantMarkdownPresentation) { self.value = value }
    }
    private static var presentations: [WeakPresentation] = []
    static func register(_ presentation: AssistantMarkdownPresentation) {
        presentations.removeAll { $0.value == nil }
        presentations.append(WeakPresentation(presentation))
    }
    static func hasRendered(_ text: String) -> Bool {
        presentations.contains { $0.value?.renderedText == text }
    }
    static var rendererDiagnostics: [[String: Int]] {
        presentations.compactMap { entry in
            guard let value = entry.value, value.renderedText.hasPrefix("# STREAM-BEGIN:") else { return nil }
            return ["rendered_bytes": value.renderedText.utf8.count,
                    "requested_bytes": value.markdownBenchmarkRequestedText.utf8.count]
        }
    }

    static func reset() {
        projections = 0; sourceRows = 0; localDeliveries = 0
        skippedParentEvents = 0; markdownPublishes = 0; markdownInitializations = 0
        lastMarkdownText = ""
    }
    static var counters: [String: Double] {
        ["projection_calls": Double(projections), "source_rows_scanned": Double(sourceRows),
         "local_deliveries": Double(localDeliveries), "parent_events_skipped": Double(skippedParentEvents),
         "markdown_publishes": Double(markdownPublishes), "markdown_initializations": Double(markdownInitializations)]
    }
}

// A non-publishing, single-entry projection cache. Geometry/auto-follow changes
// may still evaluate ChatView.body; they must not rescan 1,000 Markdown bodies.
@MainActor
final class MarkdownIsolationWindowCache: ObservableObject {
    struct Key: Equatable {
        let sessionID: String
        let generation: Int
        let sourceCount: Int
        let navigation: TranscriptWindowNavigation
        let limit: Int
        let executing: Bool
        let turnID: String?
    }
    var key: Key?
    var window: TranscriptWindow?
}

// O(1) identity-only signature. Do not retain the transcript/record across reducer
// mutation, and do not compare or hash the entire growing Markdown string.
struct MarkdownIsolationSignature: Equatable {
    let count: Int
    let messageID: String
    let partID: String
    let turnID: String

    init?(_ record: SessionRecord?) {
        guard let record, record.runState == .running, let turn = record.activeTurnId,
              let last = record.transcript.last, last.role == .assistant,
              last.id.hasPrefix("turn:\(turn):assistant"), last.parts.count == 1,
              case .text(let partID, _) = last.parts[0] else { return nil }
        count = record.transcript.count; messageID = last.id; self.partID = partID; turnID = turn
    }
}

extension AgentHostServerEvent {
    var markdownIsolationTextIdentity: (sessionID: String, sequence: Int)? {
        switch self {
        case .sessionMessageDelta(let payload): return (payload.sessionId, payload.sequence)
        case .sessionAssistantContent(let payload) where payload.phase == .delta && payload.contentType == .text:
            return (payload.sessionId, payload.sequence)
        default: return nil
        }
    }
}

@MainActor
private final class MarkdownIsolatedReplyModel: ObservableObject {
    @Published private(set) var message: PiChatMessage
    private var subscription: AnyCancellable?

    init(message: PiChatMessage) { self.message = message }

    func start(store: SessionStore, sessionID: String, messageID: String) {
        stop()
        // Reappearance catches up even if updates arrived while the row was absent.
        @MainActor func current() -> PiChatMessage? {
            guard let record = store.records[sessionID], let last = record.transcript.last,
                  last.id == messageID else { return nil }
            return PiChatMessage(message: last, isStreaming: record.runState == .running)
        }
        if let latest = current(), latest != message { message = latest }
        subscription = store.recordUpdates.sink { [weak self, weak store] ids in
            guard let self, let store, ids.contains(sessionID),
                  store.markdownContentOnlySessionIDs.contains(sessionID),
                  let record = store.records[sessionID], let last = record.transcript.last,
                  last.id == messageID else { return }
            self.message = PiChatMessage(message: last, isStreaming: record.runState == .running)
            MarkdownIsolationProbe.localDeliveries += 1
        }
    }
    func synchronize(_ fallback: PiChatMessage) {
        // Non-text structural events still flow through the parent, e.g. a tool
        // block appended to an executing message. Never keep the old text-only row.
        if message != fallback { message = fallback }
    }
    func stop() { subscription?.cancel(); subscription = nil }
}

// Only an executing reply gets this wrapper/subscription. Historical/static rows
// keep the original ChatMessageRow path; there are not 100 per-row subscriptions.
struct MarkdownIsolatedReply<Content: View>: View {
    let fallback: PiChatMessage
    let store: SessionStore
    let sessionID: String
    let content: (PiChatMessage) -> Content
    @StateObject private var model: MarkdownIsolatedReplyModel

    init(message: PiChatMessage, store: SessionStore, sessionID: String,
         @ViewBuilder content: @escaping (PiChatMessage) -> Content) {
        fallback = message; self.store = store; self.sessionID = sessionID; self.content = content
        _model = StateObject(wrappedValue: MarkdownIsolatedReplyModel(message: message))
    }
    var body: some View {
        content(model.message)
            .onChange(of: fallback) { model.synchronize($0) }
            .onAppear { model.start(store: store, sessionID: sessionID, messageID: fallback.id) }
            .onDisappear { model.stop() }
    }
}
