import Foundation
import MarkdownUI

/// Finds the last prefix of a streaming Markdown document that can be parsed
/// independently without changing the resulting block structure.
///
/// Splitting is only allowed after a blank line whose following line starts a
/// new top-level block. Fences, blockquotes, lists, tables, indented code,
/// HTML, and link reference definitions keep the boundary earlier (or disable
/// incremental parsing entirely) because they can continue across a blank line
/// or depend on the whole document.
enum StreamingMarkdownBoundary {
    /// The last prefix that can be parsed on its own.
    static func stablePrefixEnd(in text: String) -> String.Index {
        safeBlockBoundaries(in: text).last ?? text.startIndex
    }

    /// Every offset at which the document can be cut into independent
    /// top-level blocks. Empty when the document cannot be split safely (for
    /// example because it defines link references, which resolve
    /// document-wide).
    static func safeBlockBoundaries(in text: String) -> [String.Index] {
        guard text.contains("\n\n") else { return [] }
        var boundaries: [String.Index] = []
        var fence: (character: Character, count: Int)?
        var previousLineWasBlank = false
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            var lineEnd = lineStart
            while lineEnd < text.endIndex, text[lineEnd] != "\n" {
                lineEnd = text.index(after: lineEnd)
            }
            let line = text[lineStart..<lineEnd]

            if let currentFence = fence {
                if closesFence(line, fence: currentFence) {
                    fence = nil
                }
                previousLineWasBlank = false
            } else if let opening = opensFence(line) {
                fence = opening
                previousLineWasBlank = false
            } else if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                previousLineWasBlank = true
            } else {
                if isReferenceDefinition(line) {
                    // Reference links are resolved document-wide; a prefix
                    // parsed alone could render them as literal text.
                    return []
                }
                if previousLineWasBlank, isSafeBlockStart(line) {
                    boundaries.append(lineStart)
                }
                previousLineWasBlank = false
            }

            if lineEnd == text.endIndex { break }
            lineStart = text.index(after: lineEnd)
        }

        // A trailing blank line completes the last block; freeze through the
        // whitespace so the tail is empty instead of being reparsed forever.
        if fence == nil, previousLineWasBlank {
            boundaries.append(text.endIndex)
        }
        return boundaries
    }

    private static func opensFence(_ line: Substring) -> (Character, Int)? {
        let leading = line.prefix(while: { $0 == " " })
        guard leading.count <= 3 else { return nil }
        let rest = line.dropFirst(leading.count)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let run = rest.prefix(while: { $0 == marker })
        guard run.count >= 3 else { return nil }
        return (marker, run.count)
    }

    private static func closesFence(
        _ line: Substring,
        fence: (character: Character, count: Int)
    ) -> Bool {
        let leading = line.prefix(while: { $0 == " " })
        guard leading.count <= 3 else { return false }
        let rest = line.dropFirst(leading.count)
        let run = rest.prefix(while: { $0 == fence.character })
        guard run.count >= fence.count else { return false }
        return rest.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isSafeBlockStart(_ line: Substring) -> Bool {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        // Four spaces start indented code or a lazy list continuation.
        guard leading.count < 4 else { return false }
        let rest = line.dropFirst(leading.count)
        guard let first = rest.first else { return false }
        if first == ">" || first == "|" || first == "<" {
            return false
        }
        if first == "-" || first == "*" || first == "+" {
            return !isBulletMarker(rest)
        }
        if first.isNumber {
            return !isOrderedMarker(rest)
        }
        // A definition can still appear after the boundary; the caller disables
        // incremental parsing when one is present, so this is defensive.
        if first == "[", isReferenceDefinition(rest) {
            return false
        }
        return true
    }

    private static func isBulletMarker(_ line: Substring) -> Bool {
        guard let first = line.first, first == "-" || first == "*" || first == "+" else {
            return false
        }
        let remainder = line.dropFirst()
        return remainder.isEmpty || remainder.first == " " || remainder.first == "\t"
    }

    private static func isOrderedMarker(_ line: Substring) -> Bool {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let remainder = line.dropFirst(digits.count)
        guard let delimiter = remainder.first, delimiter == "." || delimiter == ")" else {
            return false
        }
        let afterDelimiter = remainder.dropFirst()
        return afterDelimiter.isEmpty
            || afterDelimiter.first == " "
            || afterDelimiter.first == "\t"
    }

    private static func isReferenceDefinition(_ line: Substring) -> Bool {
        let leading = line.prefix(while: { $0 == " " })
        guard leading.count <= 3 else { return false }
        var rest = line.dropFirst(leading.count)
        guard rest.first == "[" else { return false }
        rest = rest.dropFirst()
        guard let closing = rest.firstIndex(of: "]") else { return false }
        rest = rest[rest.index(after: closing)...]
        return rest.first == ":"
    }
}

/// One frozen slice of a streaming reply. `id` is append-only so SwiftUI can
/// keep the view (and its layout) alive while the parsed value is unchanged.
struct StreamingMarkdownSegment: Identifiable, Equatable {
    let id: Int
    let content: MarkdownContent
    /// Spacing that `BlockSequence` would have applied above/below this chunk
    /// had the document stayed a single view. Needed because each segment is
    /// its own `Markdown` view, whose first block gets no top margin.
    var leadingMargin: CGFloat = 0
    var trailingMargin: CGFloat = 0
}

/// The app renders Markdown with `Theme.gitHub`. MarkdownUI separates adjacent
/// blocks with `max(previous.bottom, next.top)` and treats an unspecified margin
/// as 0, so the only non-zero values are: headings 24/16, paragraphs, code
/// blocks and tables 0/16, thematic breaks 24/24, and lists/blockquotes 0/0.
/// Splitting the document into one view per block throws that computation away;
/// these helpers let each segment carry the margins it needs to restore it.
enum StreamingMarkdownBlockMargin {
    static let headingTop: CGFloat = 24
    static let textBottom: CGFloat = 16
    static let thematicBreak: CGFloat = 24

    /// Top margin of the block that starts the chunk.
    static func leading(of chunk: String) -> CGFloat {
        guard let line = firstLine(of: chunk) else { return 0 }
        return isHeading(line) || isThematicBreak(line) ? headingTop : 0
    }

    /// Bottom margin of the block that ends the chunk.
    static func trailing(of chunk: String) -> CGFloat {
        guard let line = lastBlockStart(of: chunk) else { return 0 }
        if isThematicBreak(line) { return thematicBreak }
        if isListItem(line) || isBlockquote(line) { return 0 }
        return textBottom
    }

    private static func firstLine(of chunk: String) -> Substring? {
        chunk.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.allSatisfy { $0 == " " || $0 == "\t" } }
    }

    /// The first line of the last block, found by walking back over the final
    /// run of non-blank lines. Chunks never end inside an open fence, and a
    /// misread inside a fenced block still yields the code block's 16 pt.
    private static func lastBlockStart(of chunk: String) -> Substring? {
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false)
        var index = lines.count - 1
        while index >= 0, lines[index].allSatisfy({ $0 == " " || $0 == "\t" }) { index -= 1 }
        guard index >= 0 else { return nil }
        while index > 0, !lines[index - 1].allSatisfy({ $0 == " " || $0 == "\t" }) { index -= 1 }
        return lines[index]
    }

    private static func isHeading(_ line: Substring) -> Bool {
        var rest = line.drop(while: { $0 == " " })
        let hashes = rest.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return false }
        rest = rest.dropFirst(hashes.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    private static func isThematicBreak(_ line: Substring) -> Bool {
        let trimmed = line.trimmingWhitespace()
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        let marks = trimmed.filter { $0 != " " && $0 != "\t" }
        return marks.count >= 3 && marks.allSatisfy { $0 == first }
    }

    private static func isListItem(_ line: Substring) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            let rest = trimmed.dropFirst()
            return rest.isEmpty || rest.first == " " || rest.first == "\t"
        }
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard (1...9).contains(digits.count) else { return false }
        let rest = trimmed.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return false }
        let tail = rest.dropFirst()
        return tail.isEmpty || tail.first == " " || tail.first == "\t"
    }

    private static func isBlockquote(_ line: Substring) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).first == ">"
    }
}

private extension Substring {
    func trimmingWhitespace() -> Substring {
        var slice = self
        while let first = slice.first, first == " " || first == "\t" { slice = slice.dropFirst() }
        while let last = slice.last, last == " " || last == "\t" { slice = slice.dropLast() }
        return slice
    }
}

/// Splits a streaming document into independently rendered top-level blocks.
///
/// This is the SwiftUI counterpart of block-level memoization: completed blocks
/// are parsed once and then never rebuilt, so only the active tail is reparsed
/// and re-rendered. Boundaries come from `StreamingMarkdownBoundary`, so the
/// resulting block structure is identical to a full parse of the same text.
struct StreamingMarkdownSegmenter {
    private var frozen: [StreamingMarkdownSegment] = []
    private var frozenOffset = 0
    private var nextID = 0
    private(set) var parsedCharacterCount = 0

    mutating func reset() {
        frozen = []
        frozenOffset = 0
        nextID = 0
        parsedCharacterCount = 0
    }

    mutating func segments(for text: String) -> [StreamingMarkdownSegment] {
        guard !text.isEmpty else {
            reset()
            return []
        }
        if text.count < frozenOffset { reset() }

        let boundaries = StreamingMarkdownBoundary.safeBlockBoundaries(in: text)
        if boundaries.isEmpty, frozenOffset > 0 {
            // A newly appended link reference definition (or any document-wide
            // construct) invalidates work already frozen against an earlier
            // prefix.
            reset()
        }

        for boundary in boundaries {
            let offset = text.distance(from: text.startIndex, to: boundary)
            guard offset > frozenOffset else { continue }
            let start = text.index(text.startIndex, offsetBy: frozenOffset)
            let end = text.index(text.startIndex, offsetBy: offset)
            let chunk = String(text[start..<end])
            frozen.append(
                StreamingMarkdownSegment(
                    id: nextID,
                    content: MarkdownContent(chunk),
                    leadingMargin: StreamingMarkdownBlockMargin.leading(of: chunk),
                    trailingMargin: StreamingMarkdownBlockMargin.trailing(of: chunk)
                )
            )
            nextID += 1
            parsedCharacterCount += chunk.count
            frozenOffset = offset
        }

        let tailStart = text.index(text.startIndex, offsetBy: frozenOffset)
        let tailText = String(text[tailStart...])
        parsedCharacterCount += tailText.count
        guard !tailText.isEmpty else { return frozen }
        return frozen + [
            StreamingMarkdownSegment(
                id: nextID,
                content: MarkdownContent(tailText),
                leadingMargin: StreamingMarkdownBlockMargin.leading(of: tailText),
                trailingMargin: StreamingMarkdownBlockMargin.trailing(of: tailText)
            )
        ]
    }
}

/// Parses only the growing tail of a streaming message. Completed blocks are
/// parsed once, concatenated into a frozen content value, and never reparsed.
struct StreamingMarkdownAccumulator {
    private var frozenContent = MarkdownContent("")
    private var frozenOffset = 0
    private var frozenTailSample = ""
    private(set) var parsedCharacterCount = 0

    mutating func reset() {
        frozenContent = MarkdownContent("")
        frozenOffset = 0
        frozenTailSample = ""
        parsedCharacterCount = 0
    }

    mutating func content(for text: String) -> MarkdownContent {
        guard !text.isEmpty else { return MarkdownContent("") }
        if text.count < frozenOffset || !frozenSampleMatches(text) {
            reset()
        }

        let boundary = StreamingMarkdownBoundary.stablePrefixEnd(in: text)
        var boundaryOffset = text.distance(from: text.startIndex, to: boundary)
        if boundaryOffset < frozenOffset {
            // A later line can invalidate an earlier boundary (for example a
            // link reference definition appended after a frozen prefix).
            reset()
            boundaryOffset = text.distance(from: text.startIndex, to: boundary)
        }
        if boundaryOffset > frozenOffset {
            let chunkStart = text.index(text.startIndex, offsetBy: frozenOffset)
            let chunkEnd = text.index(text.startIndex, offsetBy: boundaryOffset)
            let chunk = MarkdownContent(String(text[chunkStart..<chunkEnd]))
            frozenContent = MarkdownContent {
                frozenContent
                chunk
            }
            frozenOffset = boundaryOffset
            frozenTailSample = sample(text, endingAt: boundaryOffset)
            parsedCharacterCount += text.distance(from: chunkStart, to: chunkEnd)
        }

        let tailStart = text.index(text.startIndex, offsetBy: frozenOffset)
        let tail = String(text[tailStart...])
        parsedCharacterCount += tail.count
        return MarkdownContent {
            frozenContent
            MarkdownContent(tail)
        }
    }

    private func frozenSampleMatches(_ text: String) -> Bool {
        guard frozenOffset > 0 else { return true }
        return sample(text, endingAt: frozenOffset) == frozenTailSample
    }

    private func sample(_ text: String, endingAt offset: Int) -> String {
        let end = text.index(text.startIndex, offsetBy: offset)
        let start = text.index(text.startIndex, offsetBy: max(0, offset - 64))
        return String(text[start..<end])
    }
}
