import Foundation

/// One user turn as it appears on the transcript's prompt rail.
///
/// The rail is a signpost, not a second copy of the conversation: it keeps the
/// ordinal, a single-line preview and the attachment count, which is everything
/// a reader needs to recognise "the turn where I asked about X".
struct PromptRailEntry: Identifiable, Equatable {
    let id: String
    /// 1-based position among the user turns that made it onto the rail.
    let index: Int
    /// Whitespace-collapsed preview; empty when the turn only carried images.
    let text: String
    /// Unabridged prompt for the hover preview and native help.
    let fullText: String
    let imageCount: Int

    var hasText: Bool { !text.isEmpty }
}

enum PromptRailPresentation {
    /// Long previews stop being scannable, and the full text is one click away.
    static let previewLimit = 160

    static func entries(from messages: [PiChatMessage]) -> [PromptRailEntry] {
        var result: [PromptRailEntry] = []
        for message in messages where message.role == .user {
            let text = previewText(for: message)
            let imageCount = message.imageAttachments.count
            // A turn with neither text nor images would draw a tick with
            // nothing behind it, so it never earns a slot.
            guard !text.isEmpty || imageCount > 0 else { continue }
            result.append(
                PromptRailEntry(
                    id: message.id,
                    index: result.count + 1,
                    text: text,
                    fullText: message.copyableText.trimmingCharacters(in: .whitespacesAndNewlines),
                    imageCount: imageCount
                )
            )
        }
        return result
    }

    static func previewText(for message: PiChatMessage) -> String {
        let collapsed = message.copyableText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > previewLimit else { return collapsed }
        return collapsed.prefix(previewLimit)
            .trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The turn the reader is currently looking at: the last prompt whose top
    /// edge has crossed the reading line. Rows below the line end the search so
    /// a tall assistant reply can't hand the marker to the next prompt.
    static func currentPromptID(
        in entries: [PromptRailEntry],
        frames: [String: CGRect],
        readingLine: CGFloat
    ) -> String? {
        guard !entries.isEmpty else { return nil }
        var current: String?
        for entry in entries {
            guard let frame = frames[entry.id] else { continue }
            if frame.minY <= readingLine {
                current = entry.id
                continue
            }
            break
        }
        if let current { return current }
        return entries.first { frames[$0.id] != nil }?.id ?? entries.first?.id
    }
}

/// Stable hit targets and bounded geometry, independent of SwiftUI. Long
/// conversations scroll instead of compressing their marks into a smudge.
enum PromptRailLayout {
    static let tickHeight: CGFloat = 3
    static let restingWidth: CGFloat = 6
    static let expandedWidth: CGFloat = 24
    static let hoveredWidth: CGFloat = 32
    static let minimumStep: CGFloat = 22
    static let blockInset: CGFloat = 6
    static let railWidth: CGFloat = 44

    static func markWidth(isExpanded: Bool, isHovered: Bool) -> CGFloat {
        guard isExpanded else { return restingWidth }
        return isHovered ? hoveredWidth : expandedWidth
    }

    static func previewTop(center: CGFloat, cardHeight: CGFloat, height: CGFloat) -> CGFloat {
        min(max(center - cardHeight / 2, 0), max(height - cardHeight, 0))
    }

    static func railHeight(count: Int, available: CGFloat) -> CGFloat {
        let ideal = CGFloat(max(count, 1)) * minimumStep + blockInset * 2
        return min(max(ideal, 96), min(max(available, 0), 360))
    }

    /// Centers in the scrollable content, not the clipped viewport. Hit targets
    /// never move or shrink when the rail expands.
    static func tickCenters(count: Int, height: CGFloat) -> [CGFloat] {
        guard count > 0, height > 0 else { return [] }
        let contentHeight = max(height, CGFloat(count) * minimumStep + blockInset * 2)
        let block = minimumStep * CGFloat(count - 1)
        let start = (contentHeight - block) / 2
        return (0..<count).map { start + minimumStep * CGFloat($0) }
    }

    /// Slot height per tick, used for hit testing and for the hover preview's
    /// vertical anchor.
    static func step(for centers: [CGFloat]) -> CGFloat {
        centers.count > 1 ? centers[1] - centers[0] : minimumStep
    }

    static func index(atY y: CGFloat, centers: [CGFloat]) -> Int? {
        guard !centers.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let distance = abs(center - y)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        let slop = max(step(for: centers) / 2, tickHeight)
        return bestDistance <= slop ? bestIndex : nil
    }
}
