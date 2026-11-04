import Combine
import MarkdownUI
import SwiftUI

/// Parsing is owned by a persistent object, not the parent's body. Streaming
/// revisions are coalesced without caching every growing prefix of a response.
struct AssistantMarkdownView: View {
    let text: String
    let isStreaming: Bool
    let blockID: String?
    @Environment(\.transcriptMessagePresentation) private var source
    @StateObject private var presentation: AssistantMarkdownPresentation

    init(text: String, isStreaming: Bool, blockID: String? = nil) {
        self.text = text
        self.isStreaming = isStreaming
        self.blockID = blockID
        _presentation = StateObject(wrappedValue: AssistantMarkdownPresentation(text: text))
    }

    var body: some View {
        Markdown(presentation.content)
            .onAppear(perform: synchronize)
            .onChange(of: text) { if !usesSource { presentation.update(text: $0, isStreaming: isStreaming) } }
            .onChange(of: isStreaming) { if !usesSource { presentation.update(text: text, isStreaming: $0) } }
            .onChange(of: blockID) { _ in synchronize() }
            .onChange(of: source.map { ObjectIdentifier($0) }) { _ in synchronize() }
            .onDisappear { presentation.disconnect(); presentation.cancel() }
    }

    private var usesSource: Bool { source != nil && blockID != nil }
    private func synchronize() {
        if let source, let blockID { presentation.connect(to: source, blockID: blockID) }
        else { presentation.disconnect(); presentation.update(text: text, isStreaming: isStreaming) }
    }
}

@MainActor
final class AssistantMarkdownPresentation: ObservableObject {
    @Published private(set) var content: MarkdownContent
    private(set) var renderedText: String
    private var pendingText: String
    private var renderTask: Task<Void, Never>?
    private let delayNanoseconds: UInt64
    private var sourceSubscription: AnyCancellable?
    private weak var connectedSource: TranscriptMessagePresentation?
    private var connectedBlockID: String?

    init(text: String, delayNanoseconds: UInt64 = 200_000_000) {
        renderedText = text
        pendingText = text
        self.delayNanoseconds = delayNanoseconds
        content = AssistantMarkdownCache.content(for: text)
        #if DEBUG || TRANSCRIPT_ACCEPTANCE
        AssistantMarkdownDiagnostics.register(self)
        #endif
    }

    /// Feed the parser directly from the row snapshot. A persistent renderer
    /// must not depend on a parent body's onChange delivering the terminal text.
    /// Use the Published value passed to sink, not source.message (willSet).
    func connect(to source: TranscriptMessagePresentation, blockID: String) {
        if connectedSource === source, connectedBlockID == blockID, sourceSubscription != nil { return }
        disconnect()
        connectedSource = source; connectedBlockID = blockID
        sourceSubscription = source.$message.sink { [weak self] message in
            guard let self, let message else { return }
            for block in AssistantTranscriptPresentation.blocks(from: message.parts) {
                if case .text(let id, let text) = block, id == blockID {
                    self.update(text: text, isStreaming: message.isStreaming)
                    return
                }
            }
        }
    }

    func disconnect() {
        sourceSubscription?.cancel(); sourceSubscription = nil
        connectedSource = nil; connectedBlockID = nil
    }

    func update(text: String, isStreaming: Bool) {
        pendingText = text
        guard isStreaming else {
            cancel()
            render(cache: true)
            return
        }
        guard text != renderedText, renderTask == nil else { return }
        // Do not restart the timer for every token (which could starve rendering).
        renderTask = Task { [weak self, delayNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.renderTask = nil
            self.render(cache: false)
        }
    }

    func cancel() {
        renderTask?.cancel()
        renderTask = nil
    }

    private func render(cache: Bool) {
        guard pendingText != renderedText else { return }
        renderedText = pendingText
        content = cache
            ? AssistantMarkdownCache.content(for: pendingText)
            : MarkdownContent(pendingText)
    }
}

@MainActor
private enum AssistantMarkdownCache {
    private static let cache: NSCache<NSString, CachedContent> = {
        let cache = NSCache<NSString, CachedContent>()
        cache.countLimit = 200
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    private final class CachedContent {
        let content: MarkdownContent
        init(_ content: MarkdownContent) { self.content = content }
    }

    static func content(for text: String) -> MarkdownContent {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.content }
        let parsed = MarkdownContent(text)
        cache.setObject(CachedContent(parsed), forKey: key, cost: text.utf8.count)
        return parsed
    }
}

#if DEBUG || TRANSCRIPT_ACCEPTANCE
/// Read-only acceptance instrumentation. Weak references neither retain removed
/// rows nor publish/drive the UI. Not compiled into a normal Release build.
@MainActor
enum AssistantMarkdownDiagnostics {
    private final class Entry {
        let ordinal: UInt64
        weak var presentation: AssistantMarkdownPresentation?
        init(_ presentation: AssistantMarkdownPresentation, ordinal: UInt64) {
            self.presentation = presentation; self.ordinal = ordinal
        }
    }
    private static var ordinal: UInt64 = 0
    private static var entries: [Entry] = []
    static var checkpoint: UInt64 { ordinal }

    static func register(_ presentation: AssistantMarkdownPresentation) {
        ordinal &+= 1
        entries.removeAll { $0.presentation == nil }
        entries.append(Entry(presentation, ordinal: ordinal))
    }

    static func hasRendered(_ text: String, after checkpoint: UInt64) -> Bool {
        entries.contains { $0.ordinal > checkpoint && $0.presentation?.renderedText == text }
    }
}
#endif
