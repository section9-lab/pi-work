import AppKit
import SwiftUI

/// The transcript's prompt rail.
///
/// One mark per user turn, sitting in the reading gutter so it never competes
/// with the conversation. Pointing at a mark reveals that single prompt in one
/// line — enough to recognise a turn without covering the paragraph behind it —
/// and clicking jumps there. The full index is opt-in through the grip above the
/// marks, because a permanent list costs the width the transcript needs.
struct PromptRailView: View {
    let entries: [PromptRailEntry]
    let currentID: String?
    let height: CGFloat
    let onSelect: (PromptRailEntry) -> Void

    @State private var hoveredIndex: Int?
    @State private var isIndexPresented = false
    @State private var isIndexHovered = false
    @State private var presentTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?

    private let previewWidth: CGFloat = 216
    private let indexWidth: CGFloat = 288
    private let cardGap: CGFloat = 8

    private var tickArea: CGFloat {
        max(height - PromptRailLayout.gripHeight, 24)
    }

    private var centers: [CGFloat] {
        PromptRailLayout.tickCenters(count: entries.count, height: tickArea)
            .map { $0 + PromptRailLayout.gripHeight }
    }

    private var stepSize: CGFloat {
        max(PromptRailLayout.step(for: centers), PromptRailLayout.tickHeight)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            hoverPreview
            indexLayer
            rail
        }
        .frame(width: 328, height: height, alignment: .trailing)
        .animation(.easeOut(duration: 0.12), value: hoveredIndex)
        .animation(.easeOut(duration: 0.14), value: isIndexPresented)
    }

    // MARK: - Rail

    private var rail: some View {
        ZStack(alignment: .top) {
            grip

            ForEach(Array(entries.indices), id: \.self) { index in
                tick(index: index, entry: entries[index])
                    .offset(y: centers[index] - stepSize / 2)
            }
        }
        .frame(width: PromptRailLayout.railWidth, height: height, alignment: .top)
        .background(
            // Keeps the index open while the pointer travels along the marks,
            // and closes it once the pointer leaves the column for good.
            Color.clear
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        cancelDismissal()
                    } else {
                        scheduleDismissal()
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("chat.prompt_rail.title"))
    }

    private var grip: some View {
        Button(action: toggleIndex) {
            Image(systemName: "list.bullet")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.primary.opacity(isIndexPresented ? 0.66 : 0.34))
                .frame(
                    width: PromptRailLayout.railWidth,
                    height: PromptRailLayout.gripHeight,
                    alignment: .bottom
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                cancelDismissal()
                schedulePresentation()
            } else {
                scheduleDismissal()
            }
        }
        .help(L10n.string("chat.prompt_rail.open"))
        .accessibilityLabel(L10n.string("chat.prompt_rail.open"))
    }

    private func tick(index: Int, entry: PromptRailEntry) -> some View {
        let isCurrent = entry.id == currentID
        let isHovered = hoveredIndex == index
        let width: CGFloat = isHovered
            ? PromptRailLayout.hoveredWidth
            : (isCurrent ? PromptRailLayout.currentWidth : PromptRailLayout.restingWidth)

        return Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule(style: .continuous)
                    .fill(tickTint(isCurrent: isCurrent, isHovered: isHovered))
                    .frame(width: width, height: isHovered ? 3 : PromptRailLayout.tickHeight)
            }
            .frame(width: PromptRailLayout.railWidth, height: stepSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredIndex = index
            } else if hoveredIndex == index {
                hoveredIndex = nil
            }
        }
        .help(entry.hasText ? entry.text : L10n.format("chat.prompt_rail.image_only", entry.imageCount))
        .accessibilityLabel(L10n.format("chat.prompt_rail.mark", entry.index, entry.text))
    }

    private func tickTint(isCurrent: Bool, isHovered: Bool) -> Color {
        if isHovered || isCurrent {
            return AppPalette.accentBar
        }
        return Color.primary.opacity(0.22)
    }

    // MARK: - Hover preview

    @ViewBuilder
    private var hoverPreview: some View {
        if !isIndexPresented,
           let index = hoveredIndex,
           entries.indices.contains(index) {
            previewCard(entries[index])
                .padding(.trailing, PromptRailLayout.railWidth + cardGap)
                .offset(y: previewOffset(index))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func previewCard(_ entry: PromptRailEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title(for: entry))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.primary.opacity(0.84))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(L10n.format("chat.prompt_rail.position", entry.index, entries.count))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.4))

                if entry.hasText, entry.imageCount > 0 {
                    Text(L10n.format("chat.prompt_rail.image_count", entry.imageCount))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: previewWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppPalette.translucentSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: AppPalette.subtleShadow, radius: 6, y: 2)
    }

    /// Keeps the card beside its mark without letting it leave the transcript.
    private func previewOffset(_ index: Int) -> CGFloat {
        let cardHeight: CGFloat = 52
        let desired = centers[index] - height / 2
        let lower = -height / 2 + cardHeight / 2 + 6
        let upper = height / 2 - cardHeight / 2 - 6
        return min(max(desired, lower), upper)
    }

    // MARK: - Index

    @ViewBuilder
    private var indexLayer: some View {
        if isIndexPresented {
            indexPanel
                .padding(.trailing, PromptRailLayout.railWidth + cardGap)
                .transition(.opacity)
                .onHover { inside in
                    isIndexHovered = inside
                    if inside {
                        cancelDismissal()
                    } else {
                        scheduleDismissal()
                    }
                }
        }
    }

    /// Sized to its rows so a two-turn conversation doesn't get a 400pt empty
    /// card, and capped so a long one scrolls instead of running off-screen.
    private var indexPanelHeight: CGFloat {
        let chrome: CGFloat = 46
        let rows = CGFloat(entries.count) * 27 + 8
        return min(rows + chrome, min(height - 12, 420))
    }

    private var indexPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(L10n.string("chat.prompt_rail.title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.45))

                Spacer(minLength: 4)

                Text("\(entries.count)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.32))
            }
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 7)

            Divider()
                .opacity(0.4)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(entries) { entry in
                        PromptRailIndexRow(
                            entry: entry,
                            isCurrent: entry.id == currentID
                        ) {
                            closeIndex()
                            onSelect(entry)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
        .frame(width: indexWidth)
        .frame(height: indexPanelHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppPalette.translucentSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: AppPalette.raisedShadow, radius: 14, y: 5)
    }

    private func title(for entry: PromptRailEntry) -> String {
        entry.hasText
            ? entry.text
            : L10n.format("chat.prompt_rail.image_only", entry.imageCount)
    }

    // MARK: - Presentation

    private func toggleIndex() {
        if isIndexPresented {
            closeIndex()
        } else {
            presentTask?.cancel()
            isIndexPresented = true
        }
    }

    private func schedulePresentation() {
        guard !isIndexPresented else { return }
        presentTask?.cancel()
        presentTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            isIndexPresented = true
        }
    }

    private func scheduleDismissal() {
        presentTask?.cancel()
        presentTask = nil
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled, !isIndexHovered else { return }
            isIndexPresented = false
        }
    }

    private func cancelDismissal() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func closeIndex() {
        presentTask?.cancel()
        presentTask = nil
        cancelDismissal()
        isIndexPresented = false
    }
}

/// One row of the prompt index. Owning the hover state here keeps the rail's
/// own body from re-rendering every time the pointer crosses a row.
private struct PromptRailIndexRow: View {
    let entry: PromptRailEntry
    let isCurrent: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Capsule(style: .continuous)
                    .fill(isCurrent ? AppPalette.accentBar : Color.clear)
                    .frame(width: 2, height: 13)

                Text(entry.hasText
                     ? entry.text
                     : L10n.format("chat.prompt_rail.image_only", entry.imageCount))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(isCurrent ? 0.88 : 0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if entry.imageCount > 0, entry.hasText {
                    Image(systemName: "photo")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.primary.opacity(0.32))
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? AppPalette.hoverRowFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(entry.hasText ? entry.text : L10n.format("chat.prompt_rail.image_only", entry.imageCount))
        .accessibilityLabel(L10n.format("chat.prompt_rail.mark", entry.index, entry.text))
    }
}
