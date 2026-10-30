import MarkdownUI
import SwiftUI

/// Parsing is owned by a persistent object, not the parent's body. Streaming
/// revisions are coalesced without caching every growing prefix of a response.
struct AssistantMarkdownView: View {
    let text: String
    let isStreaming: Bool
    @StateObject private var presentation: AssistantMarkdownPresentation

    init(text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
        _presentation = StateObject(wrappedValue: AssistantMarkdownPresentation(text: text))
    }

    var body: some View {
        Markdown(presentation.content)
            .onAppear { presentation.update(text: text, isStreaming: isStreaming) }
            .onChange(of: text) { presentation.update(text: $0, isStreaming: isStreaming) }
            .onChange(of: isStreaming) { presentation.update(text: text, isStreaming: $0) }
            .onDisappear { presentation.cancel() }
    }
}

@MainActor
final class AssistantMarkdownPresentation: ObservableObject {
    @Published private(set) var content: MarkdownContent
    private(set) var renderedText: String
    private var pendingText: String
    private var renderTask: Task<Void, Never>?
    private let delayNanoseconds: UInt64

    init(text: String, delayNanoseconds: UInt64 = 200_000_000) {
        renderedText = text
        pendingText = text
        self.delayNanoseconds = delayNanoseconds
        content = AssistantMarkdownCache.content(for: text)
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
