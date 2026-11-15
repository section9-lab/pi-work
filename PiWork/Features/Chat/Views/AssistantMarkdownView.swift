import AppKit
import Combine
import MarkdownUI
import OSLog
import SwiftUI

/// Injectable visibility checks so UI tests can exercise the streaming render
/// gate without depending on the test host's activation or occlusion state.
@MainActor
enum MarkdownRenderActivity {
    static var isApplicationVisible: () -> Bool = {
        NSApplication.shared.occlusionState.contains(.visible)
    }
    static var isWindowVisible: (NSWindow?) -> Bool = { window in
        guard let window else { return true }
        return window.occlusionState.contains(.visible)
    }
}

/// Injectable so UI tests can exercise the VoiceOver mount policy.
@MainActor
enum AssistantMarkdownAccessibility {
    static var isVoiceOverEnabled: () -> Bool = {
        NSWorkspace.shared.isVoiceOverEnabled
    }
}

/// Selects how streaming Markdown is turned into views.
///
/// - `wholeDocument`: one `Markdown` view for the entire reply. Every streaming
///   tick rebuilds and re-lays out the whole document. Retained as the
///   `PIWORK_MARKDOWN_BLOCK_MEMO=0` fallback.
/// - `blockMemo`: one memoized view per frozen top-level block, active tail
///   last. Completed blocks skip body evaluation.
/// - `virtualizedBlockMemo`: the same segments in a `LazyVStack`. Fast, but a
///   lazy stack reports a different document height depending on scroll
///   position (measured up to 595 pt on a 9 KB reply), which corrupts the transcript
///   anchor frames. Kept for benchmarking only.
/// - `blockWindow`: eager stack that only mounts the newest blocks; older
///   blocks become fixed-height placeholders measured while they were mounted.
///   Exact geometry, block-level cost.
///
/// Defaults to `blockWindow`, chosen once at launch. `PIWORK_MARKDOWN_BLOCK_MEMO`
/// (`0`, `1`, `2`, `3`) lets the acceptance benchmark A/B them in one binary.
@MainActor
enum AssistantMarkdownRendering {
    enum Strategy {
        case wholeDocument
        case blockMemo
        case virtualizedBlockMemo
        case blockWindow

        var logName: String {
            switch self {
            case .wholeDocument: return "whole_document"
            case .blockMemo: return "block_memo"
            case .virtualizedBlockMemo: return "block_memo_lazy"
            case .blockWindow: return "block_window"
            }
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.vibevibe.pi-work",
        category: "Markdown"
    )

    /// Mutable so tests can exercise each path. Set once from the environment
    /// at first use in the app; `PIWORK_MARKDOWN_BLOCK_MEMO=0` restores the
    /// previous whole-document rendering.
    static var strategy: Strategy = {
        let resolved: Strategy
        switch ProcessInfo.processInfo.environment["PIWORK_MARKDOWN_BLOCK_MEMO"] {
        case "0": resolved = .wholeDocument
        case "1": resolved = .blockMemo
        case "2": resolved = .virtualizedBlockMemo
        default: resolved = .blockWindow
        }
        logger.notice("assistant markdown strategy=\(resolved.logName, privacy: .public)")
        return resolved
    }()

    static var usesSegments: Bool { strategy != .wholeDocument }

    static var blockMode: AssistantMarkdownBlocksView.Mode {
        switch strategy {
        case .wholeDocument, .blockMemo: return .eager
        case .virtualizedBlockMemo: return .lazyStack
        case .blockWindow: return .windowed
        }
    }
}

/// Parsing is owned by a persistent object, not the parent's body. Streaming
/// revisions are coalesced without caching every growing prefix of a response.
struct AssistantMarkdownView: View {
    let text: String
    let isStreaming: Bool
    let blockID: String?
    let messageID: String?
    @Environment(\.transcriptMessagePresentation) private var source
    @Environment(\.transcriptViewport) private var transcriptViewport
    @StateObject private var presentation: AssistantMarkdownPresentation

    init(
        text: String,
        isStreaming: Bool,
        blockID: String? = nil,
        messageID: String? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.blockID = blockID
        self.messageID = messageID
        _presentation = StateObject(wrappedValue: AssistantMarkdownPresentation(text: text))
    }

    var body: some View {
        Group {
            // The segment path is the streaming renderer. `content` is always
            // seeded, so an empty segment list falls back instead of silently
            // showing an empty reply.
            if AssistantMarkdownRendering.usesSegments, !presentation.segments.isEmpty {
                AssistantMarkdownBlocksView(
                    segments: presentation.segments,
                    mode: AssistantMarkdownRendering.blockMode,
                    resetToken: presentation.resetToken
                )
            } else {
                Markdown(presentation.content)
            }
        }
        .onAppear(perform: synchronize)
            .onChange(of: text) { if !usesSource { presentation.update(text: $0, isStreaming: isStreaming) } }
            .onChange(of: isStreaming) { if !usesSource { presentation.update(text: text, isStreaming: $0) } }
            .onChange(of: blockID) { _ in synchronize() }
            .onChange(of: messageID) { _ in synchronize() }
            .onChange(of: source.map { ObjectIdentifier($0) }) { _ in synchronize() }
            .onDisappear { presentation.disconnect(); presentation.cancel() }
    }

    private var usesSource: Bool { source != nil && blockID != nil }
    private func synchronize() {
        presentation.renderAllowed = renderGate()
        if let source, let blockID { presentation.connect(to: source, blockID: blockID) }
        else { presentation.disconnect(); presentation.update(text: text, isStreaming: isStreaming) }
    }

    /// Markdown is only parsed for streaming rows that are at or near the
    /// viewport, and never while the application is hidden or fully occluded.
    /// The model keeps accumulating text; the next visible tick or completion
    /// renders it. Non-streaming content always renders so final state is exact.
    private func renderGate() -> () -> Bool {
        let viewport = transcriptViewport
        let messageID = messageID
        return {
            guard MarkdownRenderActivity.isApplicationVisible() else { return false }
            guard let viewport else { return true }
            guard MarkdownRenderActivity.isWindowVisible(viewport.scrollView?.window) else {
                return false
            }
            guard let messageID else { return true }
            return viewport.isRowVisible(messageID)
        }
    }
}

/// Block-level memoization for streaming Markdown.
///
/// Each frozen segment renders through its own `Markdown` view wrapped in
/// `.equatable()`, so SwiftUI skips body evaluation for every block whose
/// parsed content did not change (the SwiftUI counterpart of wrapping a block
/// in `React.memo`). Only the active tail rebuilds.
struct AssistantMarkdownBlocksView: View {
    enum Mode: String {
        /// `wholeDocument`/`blockMemo`: every block stays mounted.
        case eager
        /// `virtualizedBlockMemo`: lazy measurement.
        case lazyStack
        /// `blockWindow`: newest blocks mounted, older ones height-exact placeholders.
        case windowed
    }

    let segments: [StreamingMarkdownSegment]
    let mode: Mode
    /// Changes whenever segment ids are reused (shrink, completion collapse,
    /// retry). Cached placeholder heights must not survive that.
    let resetToken: Int

    /// Blocks kept mounted at the end of a reply. The tail is always included.
    static let mountedBlockWindow = 6

    @State private var measuredHeights: [Int: CGFloat] = [:]
    @State private var measuredWidth: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.transcriptFollowsTail) private var followsTail

    var body: some View {
        if mode == .lazyStack {
            LazyVStack(alignment: .leading, spacing: 0) { rows(window: Int.max) }
        } else {
            VStack(alignment: .leading, spacing: 0) { rows(window: liveWindow) }
                .background(widthProbe)
                .onPreferenceChange(AssistantMarkdownWidthKey.self) { width in
                    guard width > 0, abs(width - measuredWidth) > 0.5 else { return }
                    // Heights are width-dependent: drop them and mount one full
                    // pass so every block is remeasured before windowing resumes.
                    measuredWidth = width
                    measuredHeights.removeAll(keepingCapacity: true)
                }
                .onPreferenceChange(AssistantMarkdownHeightKey.self) { values in
                    for (id, height) in values where height > 0 {
                        measuredHeights[id] = height
                    }
                }
                .onChange(of: resetToken) { _ in
                    measuredHeights.removeAll(keepingCapacity: true)
                }
                .onChange(of: dynamicTypeSize) { _ in
                    measuredHeights.removeAll(keepingCapacity: true)
                }
        }
    }

    /// Windowing needs every frozen block to have a height; until then (first
    /// pass, or after a width change) everything stays mounted. VoiceOver always
    /// sees the whole reply, matching the transcript's row policy.
    private var liveWindow: Int {
        guard mode == .windowed, !segments.isEmpty else { return Int.max }
        let allMeasured = segments.dropLast().allSatisfy { measuredHeights[$0.id] != nil }
        return Self.mountedWindow(
            mode: mode,
            allMeasured: allMeasured,
            voiceOver: AssistantMarkdownAccessibility.isVoiceOverEnabled(),
            followsTail: followsTail
        )
    }

    /// Windowing is only safe while the reader is pinned to the tail: SwiftUI is
    /// not invalidated on every scroll tick, so a fixed window would otherwise
    /// leave previously scrolled-to blocks blank. Off the tail everything stays
    /// mounted, which costs the eager-layout price but never hides content.
    static func mountedWindow(
        mode: Mode,
        allMeasured: Bool,
        voiceOver: Bool,
        followsTail: Bool = true
    ) -> Int {
        guard mode == .windowed, allMeasured, !voiceOver, followsTail else { return Int.max }
        return mountedBlockWindow
    }

    /// `BlockSequence` would have used `max(previous.bottom, next.top)` between
    /// adjacent blocks; each segment carries those margins.
    private func gap(before index: Int) -> CGFloat {
        guard index > 0, index < segments.count else { return 0 }
        return max(segments[index - 1].trailingMargin, segments[index].leadingMargin)
    }

    @ViewBuilder
    private func rows(window: Int) -> some View {
        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
            let height = measuredHeights[segment.id]
            if mode == .windowed, index < segments.count - window, let height {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .accessibilityHidden(true)
                    .padding(.top, gap(before: index))
            } else {
                AssistantMarkdownSegmentView(content: segment.content)
                    .equatable()
                    .background(heightProbe(for: segment.id))
                    .padding(.top, gap(before: index))
            }
        }
    }

    private var widthProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: AssistantMarkdownWidthKey.self, value: proxy.size.width)
        }
    }

    private func heightProbe(for id: Int) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: AssistantMarkdownHeightKey.self, value: [id: proxy.size.height])
        }
    }
}

private struct AssistantMarkdownWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct AssistantMarkdownHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Equality is deliberately limited to the parsed content: the segment id
/// must not take part, or appending a block would invalidate every view.
private struct AssistantMarkdownSegmentView: View, Equatable {
    let content: MarkdownContent

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.content == rhs.content }

    var body: some View { Markdown(content) }
}

@MainActor
final class AssistantMarkdownPresentation: ObservableObject {
    @Published private(set) var content: MarkdownContent
    /// Frozen top-level blocks plus the active tail. Populated only when
    /// `AssistantMarkdownRendering.usesSegments` is enabled.
    @Published private(set) var segments: [StreamingMarkdownSegment] = []
    /// Bumped when segment ids restart from zero so cached block heights cannot
    /// be applied to different content.
    @Published private(set) var resetToken = 0
    /// Set by the owning row. Evaluated on every streaming update so an
    /// offscreen or occluded reply stops parsing without losing latest text.
    var renderAllowed: (() -> Bool)?
    private(set) var renderedText: String
    private var pendingText: String
    private var renderTask: Task<Void, Never>?
    private let delayNanoseconds: UInt64
    private var streamingAccumulator = StreamingMarkdownAccumulator()
    private var segmenter = StreamingMarkdownSegmenter()
    private var sourceSubscription: AnyCancellable?
    private weak var connectedSource: TranscriptMessagePresentation?
    private var connectedBlockID: String?

    init(text: String, delayNanoseconds: UInt64 = 200_000_000) {
        renderedText = text
        pendingText = text
        self.delayNanoseconds = delayNanoseconds
        content = AssistantMarkdownCache.content(for: text)
        if AssistantMarkdownRendering.usesSegments {
            // Completed and historical messages never streamed through
            // `render(cache:)`, so their single segment has to be seeded here.
            segments = [StreamingMarkdownSegment(id: 0, content: content)]
        }
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
        guard renderAllowed?() ?? true else {
            cancel()
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
        if cache || pendingText.count < renderedText.count { resetToken &+= 1 }
        renderedText = pendingText
        if cache {
            streamingAccumulator.reset()
            segmenter.reset()
            content = AssistantMarkdownCache.content(for: pendingText)
            if AssistantMarkdownRendering.usesSegments {
                // Completion keeps one exact parse so the final state is
                // identical to the whole-document path.
                segments = [StreamingMarkdownSegment(id: 0, content: content)]
            }
        } else if AssistantMarkdownRendering.usesSegments {
            // Parse only the growing tail; completed blocks stay frozen.
            segments = segmenter.segments(for: pendingText)
        } else {
            // Parse only the growing tail; completed blocks are frozen.
            content = streamingAccumulator.content(for: pendingText)
        }
    }
}

@MainActor
enum AssistantMarkdownCache {
    private static let cache: NSCache<NSString, CachedContent> = {
        let cache = NSCache<NSString, CachedContent>()
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func removeAll() {
        cache.removeAllObjects()
    }

    private final class CachedContent {
        let content: MarkdownContent
        init(_ content: MarkdownContent) { self.content = content }
    }

    static func content(for text: String) -> MarkdownContent {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.content }
        let parsed = MarkdownContent(text)
        // Parsed ASTs are several times larger than the source. Charge the
        // cache for that so a few hundred completed replies cannot retain tens
        // of megabytes invisibly.
        cache.setObject(CachedContent(parsed), forKey: key, cost: max(1, text.utf8.count * 4))
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

    static func renderedTexts(after checkpoint: UInt64) -> [String] {
        entries
            .filter { $0.ordinal > checkpoint }
            .compactMap { $0.presentation?.renderedText }
    }
}
#endif
