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
    static func stablePrefixEnd(in text: String) -> String.Index {
        guard text.contains("\n\n") else { return text.startIndex }
        var lastSafe = text.startIndex
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
                    return text.startIndex
                }
                if previousLineWasBlank, isSafeBlockStart(line) {
                    lastSafe = lineStart
                }
                previousLineWasBlank = false
            }

            if lineEnd == text.endIndex { break }
            lineStart = text.index(after: lineEnd)
        }

        // A trailing blank line completes the last block; freeze through the
        // whitespace so the tail is empty instead of being reparsed forever.
        if fence == nil, previousLineWasBlank {
            lastSafe = text.endIndex
        }
        return lastSafe
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
