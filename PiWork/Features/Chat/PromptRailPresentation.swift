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

/// Geometry for the rail. Kept free of SwiftUI so the spacing rules — the part
/// that decides whether a 60-turn conversation still reads as separate marks —
/// can be checked without a running app.
enum PromptRailLayout {
    static let tickHeight: CGFloat = 2.5
    static let restingWidth: CGFloat = 9
    static let currentWidth: CGFloat = 14
    static let hoveredWidth: CGFloat = 18
    /// Below this the marks merge into a single smudge.
    static let minimumStep: CGFloat = 7
    static let blockInset: CGFloat = 6
    /// Column the marks live in; also the hit area around them.
    static let railWidth: CGFloat = 22
    static let gripHeight: CGFloat = 26

    static func railHeight(count: Int, available: CGFloat) -> CGFloat {
        let ideal = CGFloat(max(count, 1)) * 15 + blockInset * 2 + gripHeight
        let ceiling = max(available, 96)
        return min(max(ideal, 96), min(ceiling, 460))
    }

    /// Evenly distributed within the rail, compressed by `minimumStep` only as
    /// far as the available height allows. A single turn sits in the middle.
    static func tickCenters(count: Int, height: CGFloat) -> [CGFloat] {
        guard count > 0, height > 0 else { return [] }
        guard count > 1 else { return [height / 2] }
        let usable = max(height - blockInset * 2 - tickHeight, tickHeight)
        let widest = usable / CGFloat(count - 1)
        let preferred = max(usable / CGFloat(count), minimumStep)
        let step = min(preferred, max(widest, tickHeight))
        let block = step * CGFloat(count - 1)
        let start = (height - block) / 2
        return (0..<count).map { start + step * CGFloat($0) }
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
