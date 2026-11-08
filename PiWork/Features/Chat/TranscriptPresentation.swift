import Combine
import SwiftUI

struct TranscriptRowSourceSpan: Equatable {
    let firstID: String
    let lastID: String
    var isGrouped: Bool { firstID != lastID }
}

/// One bounded projection per conversation surface. Content-only updates retain
/// membership/IDs; a row-owned observer supplies the growing reply independently.
/// Navigation reuses the filtered source, not another full scan of Markdown text.
@MainActor
final class TranscriptPresentationCache: ObservableObject {
    @Published private(set) var revision: UInt64 = 0

    private struct SourceKey: Equatable {
        let sessionID: String
        let structuralRevision: UInt64
        let count: Int
        let executing: Bool
        let turnID: String?
    }
    private struct WindowKey: Equatable {
        let source: SourceKey
        let navigation: TranscriptWindowNavigation
        let limit: Int
    }
    private var sourceKey: SourceKey?
    private var visibleSource: [SessionTranscriptMessage] = []
    private var sourceIDs: [String] = []
    private var streamingID: String?
    private var windowKey: WindowKey?
    private var window: TranscriptWindow?

    func clear() {
        sourceKey = nil; windowKey = nil; window = nil
        visibleSource = []; sourceIDs = []; streamingID = nil
    }

    func invalidate() {
        clear()
        // A real published dependency, not a discarded read of a State counter.
        revision &+= 1
    }

    func project(record: SessionRecord, structuralRevision: UInt64,
                 navigation: TranscriptWindowNavigation, limit: Int) -> TranscriptWindow {
        let key = SourceKey(sessionID: record.id, structuralRevision: structuralRevision,
            count: record.transcript.count, executing: record.isExecutingTurn, turnID: record.activeTurnId)
        if sourceKey != key {
            streamingID = record.streamingTranscriptMessageID
            visibleSource = record.transcript.filter { message in
                PiChatMessage.hasVisibleContent(parts: message.parts,
                    hasCompaction: message.compaction != nil, isStreaming: message.id == streamingID)
            }
            sourceIDs = visibleSource.map(\.id)
            sourceKey = key; windowKey = nil; window = nil
        }
        let nextKey = WindowKey(source: key, navigation: navigation, limit: limit)
        if windowKey == nextKey, let window { return window }
        let range = navigation.range(in: sourceIDs, presentationLimit: limit)
        let source = visibleSource[range]
        let displayed = source.map { PiChatMessage(message: $0, isStreaming: $0.id == streamingID) }
        let grouped = AssistantTranscriptPresentation.groupAdjacentTools(in: displayed)
        var result = TranscriptWindow(messages: grouped,
            hiddenCount: range.lowerBound + (record.hasEarlierMessages ? 1 : 0),
            sourceIDs: sourceIDs, hasNewerMessages: range.upperBound < sourceIDs.count,
            hasCachedEarlierMessages: range.lowerBound > 0)
        result.sourceRange = range
        // Group identity is the first source ID, in original order. Keep spans
        // so visible tool parts, not an entire tall group, can anchor navigation.
        let positions = Dictionary(source.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let selectedIDs = source.map(\.id)
        result.sourcePositions = positions.mapValues { $0 + range.lowerBound }
        for (index, message) in grouped.enumerated() {
            guard let first = positions[message.id] else { continue }
            let end = index + 1 < grouped.count ? (positions[grouped[index + 1].id] ?? selectedIDs.count) : selectedIDs.count
            if end > first {
                result.sourceSpans[message.id] = TranscriptRowSourceSpan(firstID: selectedIDs[first], lastID: selectedIDs[end - 1])
            }
        }
        for message in source {
            for part in message.parts { result.sourceMessageIDsByPartID[part.id] = message.id }
        }
        windowKey = nextKey; window = result
        return result
    }
}

/// Persistent across streaming -> completed, so selection/copy/hover state in
/// ChatMessageRow is not thrown away by changing the view's structural type.
/// Content packets update only their exact message ID. Structural packets also
/// refresh retained rows, including older generations and same-ID snapshot repairs.
/// Unchanged snapshots publish nothing and do not repeat timestamp conversion.
@MainActor
final class TranscriptMessagePresentation: ObservableObject {
    @Published private(set) var message: PiChatMessage?
    private var sessionID: String?
    private var messageID: String?
    private weak var store: SessionStore?
    private var subscription: AnyCancellable?
    private var sourceIndex: Int?
    private var lastSource: SessionTranscriptMessage?
    private var lastStreaming: Bool?

    func configure(fallback: PiChatMessage, store: SessionStore, sessionID: String, isGrouped: Bool) {
        if self.store !== store || self.sessionID != sessionID || messageID != fallback.id {
            stop(); if message != nil { message = nil }
            sourceIndex = nil; lastSource = nil; lastStreaming = nil
            self.store = store; self.sessionID = sessionID; messageID = fallback.id
        }
        // A grouped row is a projection of multiple source messages. Never
        // replace it with only the first raw source message from the Store.
        if isGrouped {
            stop(); sourceIndex = nil; lastSource = nil; lastStreaming = nil
            if message != fallback { message = fallback }
            return
        }
        guard let record = store.records[sessionID] else { stop(); return }
        refresh(record: record, streamingID: store.streamingTranscriptMessageID(sessionID: sessionID))
        if subscription == nil {
            subscription = store.transcriptUpdates.sink { [weak self, weak store] update in
                guard let self, let store, self.store === store,
                      self.sessionID == sessionID, self.messageID == fallback.id,
                      update.structuralSessionIDs.contains(sessionID)
                        || update.contentMessageIDs[sessionID]?.contains(fallback.id) == true,
                      let record = store.records[sessionID] else { return }
                self.refresh(record: record, streamingID: store.streamingTranscriptMessageID(sessionID: sessionID))
            }
        }
    }

    private func refresh(record: SessionRecord, streamingID: String?) {
        guard let messageID else { return }
        let source: SessionTranscriptMessage
        if let index = sourceIndex, record.transcript.indices.contains(index), record.transcript[index].id == messageID {
            source = record.transcript[index]
        } else if let last = record.transcript.last, last.id == messageID {
            source = last; sourceIndex = record.transcript.count - 1
        } else if let index = record.transcript.firstIndex(where: { $0.id == messageID }) {
            source = record.transcript[index]; sourceIndex = index
        } else { return }
        let streaming = streamingID == messageID
        guard lastSource != source || lastStreaming != streaming else { return }
        lastSource = source; lastStreaming = streaming
        let latest = PiChatMessage(message: source, isStreaming: streaming)
        if message != latest { message = latest }
    }

    func stop() { subscription?.cancel(); subscription = nil }
}

struct TranscriptMessageSnapshotView<Content: View>: View {
    let fallback: PiChatMessage
    let store: SessionStore
    let sessionID: String
    let isGrouped: Bool
    let content: (PiChatMessage) -> Content
    @StateObject private var presentation = TranscriptMessagePresentation()

    init(fallback: PiChatMessage, store: SessionStore, sessionID: String, isGrouped: Bool,
         @ViewBuilder content: @escaping (PiChatMessage) -> Content) {
        self.fallback = fallback; self.store = store; self.sessionID = sessionID
        self.isGrouped = isGrouped; self.content = content
    }

    private struct Identity: Equatable {
        let store: ObjectIdentifier
        let sessionID: String
        let messageID: String
    }
    private var identity: Identity { Identity(store: ObjectIdentifier(store), sessionID: sessionID, messageID: fallback.id) }

    var body: some View {
        content(isGrouped ? fallback : (presentation.message ?? fallback))
            .environment(\.transcriptMessagePresentation, presentation)
            .onAppear(perform: configure)
            .onChange(of: fallback) { _ in configure() }
            .onChange(of: identity) { _ in configure() }
            .onChange(of: isGrouped) { _ in configure() }
            .onDisappear { presentation.stop() }
    }

    private func configure() {
        presentation.configure(fallback: fallback, store: store, sessionID: sessionID, isGrouped: isGrouped)
    }
}

struct TranscriptVisibleRow: Identifiable {
    enum ID: Hashable { case message(String), tools(String) }
    let id: ID
    let message: PiChatMessage
}

/// Pure row-window decision for placeholder virtualization. `nil` means the
/// caller must mount every row (navigation, restoration, VoiceOver, no height).
enum TranscriptVirtualization {
    static func mountedRowIDs(
        rows: [TranscriptVisibleRow],
        viewportHeight: CGFloat,
        buffer: CGFloat,
        isMeasured: (TranscriptVisibleRow) -> Bool,
        frame: (TranscriptVisibleRow) -> CGRect?,
        mustMount: (TranscriptVisibleRow) -> Bool
    ) -> Set<TranscriptVisibleRow.ID>? {
        guard viewportHeight > 0 else { return nil }
        var mounted: Set<TranscriptVisibleRow.ID> = []
        for row in rows {
            if mustMount(row) {
                mounted.insert(row.id)
                continue
            }
            guard isMeasured(row), let frame = frame(row) else {
                mounted.insert(row.id)
                continue
            }
            if frame.maxY > -buffer && frame.minY < viewportHeight + buffer {
                mounted.insert(row.id)
            }
        }
        return mounted
    }
}

/// Manual tool expansion survives group merges/splits while navigating one
/// session. Preferences are attached to tool identities, not a transient group
/// header ID. Latest explicit user selection wins if two groups later merge.
@MainActor
final class TranscriptToolExpansionState: ObservableObject {
    private var revision = 0
    private var selections: [String: (revision: Int, value: Bool)] = [:]
    private var detailSelections: [String: Bool] = [:]
    private var groupIdentities: [String: String] = [:]

    func groupIdentity(for tools: [SessionToolRecord]) -> String? {
        guard let first = tools.first else { return nil }
        let identity = tools.compactMap { groupIdentities[$0.id] }.first ?? "tool-group:\(first.id)"
        for tool in tools { groupIdentities[tool.id] = identity }
        return identity
    }

    func rows(for messages: [PiChatMessage]) -> [TranscriptVisibleRow] {
        var used: Set<TranscriptVisibleRow.ID> = []
        return messages.map { message in
            let tools = message.parts.compactMap { part -> SessionToolRecord? in
                if case .tool(let tool) = part { return tool }; return nil
            }
            var id = TranscriptVisibleRow.ID.message(message.id)
            if message.role == .assistant, !tools.isEmpty, tools.count == message.parts.count,
               let identity = groupIdentity(for: tools) {
                id = .tools(identity)
            }
            // Malformed duplicate tool IDs must not create duplicate row keys.
            if !used.insert(id).inserted { id = .message(message.id); used.insert(id) }
            return TranscriptVisibleRow(id: id, message: message)
        }
    }

    func selection(for tools: [SessionToolRecord]) -> Bool? {
        tools.compactMap { selections[$0.id] }.max { $0.revision < $1.revision }?.value
    }
    func set(_ value: Bool, for tools: [SessionToolRecord]) {
        revision &+= 1
        for tool in tools { selections[tool.id] = (revision, value) }
    }
    func detailSelection(for toolID: String) -> Bool? { detailSelections[toolID] }
    func setDetail(_ value: Bool, for toolID: String) { detailSelections[toolID] = value }
    func reset() {
        selections.removeAll(keepingCapacity: true)
        detailSelections.removeAll(keepingCapacity: true)
        groupIdentities.removeAll(keepingCapacity: true)
    }
}

private struct TranscriptMessagePresentationKey: EnvironmentKey {
    static let defaultValue: TranscriptMessagePresentation? = nil
}

private struct TranscriptToolExpansionKey: EnvironmentKey {
    static let defaultValue: TranscriptToolExpansionState? = nil
}

private struct TranscriptViewportKey: EnvironmentKey {
    static let defaultValue: TranscriptViewport? = nil
}

extension EnvironmentValues {
    var transcriptViewport: TranscriptViewport? {
        get { self[TranscriptViewportKey.self] }
        set { self[TranscriptViewportKey.self] = newValue }
    }
    var transcriptMessagePresentation: TranscriptMessagePresentation? {
        get { self[TranscriptMessagePresentationKey.self] }
        set { self[TranscriptMessagePresentationKey.self] = newValue }
    }
    var transcriptToolExpansion: TranscriptToolExpansionState? {
        get { self[TranscriptToolExpansionKey.self] }
        set { self[TranscriptToolExpansionKey.self] = newValue }
    }
}

struct TranscriptPartFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
