import AppKit
import SwiftUI

/// A quiet mark for each user turn. The marks themselves expand into the index;
/// no separate grip or list competes with the conversation.
struct PromptRailView: View {
    let entries: [PromptRailEntry]
    let currentID: String?
    let height: CGFloat
    let onSelect: (PromptRailEntry) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focusedID: String?
    @State private var isExpanded = false
    @State private var hoveredID: String?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var previewHeight: CGFloat = 72
    @State private var collapseTask: Task<Void, Never>?

    private let previewWidth: CGFloat = 280
    private let previewGap: CGFloat = 10
    private let coordinateSpace = "promptRail"

    private var previewID: String? { hoveredID ?? focusedID }
    private var expanded: Bool { isExpanded || focusedID != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        mark(entry, index: index)
                    }
                }
                .padding(.vertical, PromptRailLayout.blockInset)
                .frame(minHeight: height)
            }
            .scrollIndicators(.hidden)
            .frame(width: PromptRailLayout.railWidth, height: height)
            .contentShape(Rectangle())
            .onHover(perform: updateHover)
            .coordinateSpace(name: coordinateSpace)
            .onPreferenceChange(PromptRailFramesKey.self) { rowFrames = $0 }
            .onPreferenceChange(PromptRailPreviewHeightKey.self) { previewHeight = $0 }
            .overlay(alignment: .topTrailing) {
                preview
            }
            .onAppear { revealCurrent(using: proxy) }
            .onChange(of: currentID) { _ in
                if !expanded { revealCurrent(using: proxy) }
            }
            .onChange(of: expanded) { value in
                if !value { revealCurrent(using: proxy) }
            }
            .onExitCommand {
                focusedID = nil
                hoveredID = nil
                isExpanded = false
            }
            .onDisappear {
                collapseTask?.cancel()
                collapseTask = nil
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("chat.prompt_rail.title"))
            .accessibilityIdentifier("session-prompt-rail")
        }
    }

    private func mark(_ entry: PromptRailEntry, index: Int) -> some View {
        let isCurrent = entry.id == currentID
        let isPointed = entry.id == previewID
        let width = PromptRailLayout.markWidth(isExpanded: expanded, isHovered: isPointed)
        let origin = entries.firstIndex { $0.id == previewID || $0.id == currentID } ?? 0
        let delay = Double(min(abs(index - origin), 8)) * 0.015

        return Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule(style: .continuous)
                    .fill(markTint(isCurrent: isCurrent, isPointed: isPointed))
                    .frame(
                        width: width,
                        height: differentiateWithoutColor && isCurrent ? 5 : PromptRailLayout.tickHeight
                    )
                    .padding(.trailing, PromptRailLayout.blockInset)
            }
            // Stable hit targets: expanding horizontally must not move the row
            // out from under the pointer or unexpectedly change the selection.
            .frame(width: PromptRailLayout.railWidth, height: PromptRailLayout.minimumStep)
            .contentShape(Rectangle())
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18).delay(delay),
                value: expanded
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isPointed)
        }
        .buttonStyle(.plain)
        .id(entry.id)
        .focused($focusedID, equals: entry.id)
        .onHover { inside in
            if inside {
                hoveredID = entry.id
            } else if hoveredID == entry.id {
                hoveredID = nil
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PromptRailFramesKey.self,
                    value: [entry.id: geometry.frame(in: .named(coordinateSpace))]
                )
            }
        }
        .help(title(for: entry))
        .accessibilityLabel(L10n.format("chat.prompt_rail.mark", entry.index, title(for: entry)))
        .accessibilityIdentifier("prompt-rail-\(entry.id)")
        .accessibilityValue(isCurrent ? L10n.string("chat.prompt_rail.current") : "")
    }

    private func markTint(isCurrent: Bool, isPointed: Bool) -> Color {
        if isCurrent || isPointed { return AppPalette.accentBar }
        return Color.primary.opacity(contrast == .increased ? 0.6 : 0.28)
    }

    @ViewBuilder
    private var preview: some View {
        if expanded,
           let id = previewID,
           let entry = entries.first(where: { $0.id == id }),
           let frame = rowFrames[id],
           frame.midY >= 0, frame.midY <= height {
            // A bounded preview stays inside the transcript even for a mark at
            // either edge. Native help exposes the unabridged prompt as well.
            let cardHeight = min(height, previewHeight)
            VStack(alignment: .leading, spacing: 8) {
                Text(title(for: entry))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(max(1, min(7, Int((height - 52) / 18))))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text(L10n.format("chat.prompt_rail.position", entry.index, entries.count))
                        .monospacedDigit()
                    if entry.hasText, entry.imageCount > 0 {
                        Text(L10n.format("chat.prompt_rail.image_count", entry.imageCount))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: previewWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: PromptRailPreviewHeightKey.self, value: geometry.size.height)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .offset(
                x: -(PromptRailLayout.railWidth + previewGap),
                y: PromptRailLayout.previewTop(center: frame.midY, cardHeight: cardHeight, height: height)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func title(for entry: PromptRailEntry) -> String {
        entry.hasText ? entry.fullText : L10n.format("chat.prompt_rail.image_only", entry.imageCount)
    }

    private func updateHover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            isExpanded = true
        } else {
            hoveredID = nil
            collapseTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                isExpanded = false
            }
        }
    }

    private func revealCurrent(using proxy: ScrollViewProxy) {
        if let currentID { proxy.scrollTo(currentID, anchor: .center) }
    }
}

private struct PromptRailPreviewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 72

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PromptRailFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
