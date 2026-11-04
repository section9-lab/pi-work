import Foundation

/// At most 100 source messages are mounted, even while reading history. A pinned
/// end ID survives appended replies and prepended remote pages. Overlap preserves
/// a reading anchor; callers can further constrain movement to keep the viewport.
struct TranscriptWindowNavigation: Equatable {
    static let batchSize = TranscriptWindow.batchSize
    static let maximumCount = batchSize
    static let navigationStep = max(1, batchSize - 20)

    private(set) var count = batchSize
    private(set) var endID: String?

    func range(in ids: [String], presentationLimit: Int? = nil) -> Range<Int> {
        let end = endID.flatMap { id in ids.firstIndex(of: id).map { $0 + 1 } } ?? ids.count
        let visibleCount = min(count, max(0, presentationLimit ?? count))
        return max(0, end - visibleCount)..<end
    }

    mutating func revealEarlier(in ids: [String], retainingThroughID: String? = nil) {
        let current = range(in: ids)
        guard current.lowerBound > 0 else { return }
        var shift = min(Self.navigationStep, current.lowerBound)
        if let id = retainingThroughID, let index = ids.firstIndex(of: id), current.contains(index) {
            shift = min(shift, current.upperBound - index - 1)
        }
        guard shift > 0 else { return }
        endID = ids[current.upperBound - shift - 1]
    }

    mutating func revealNewer(in ids: [String], retainingFromID: String? = nil) {
        let current = range(in: ids)
        guard current.upperBound < ids.count else { return }
        var shift = min(Self.navigationStep, ids.count - current.upperBound)
        if let id = retainingFromID, let index = ids.firstIndex(of: id), current.contains(index) {
            shift = min(shift, index - current.lowerBound)
        }
        guard shift > 0 else { return }
        endID = ids[current.upperBound + shift - 1]
    }

    mutating func jump(to id: String, in ids: [String]) {
        guard let index = ids.firstIndex(of: id) else { return }
        let end = min(ids.count, index + 1 + Self.maximumCount / 2)
        endID = ids[end - 1]
    }

    mutating func pin(in ids: [String]) {
        if endID == nil { endID = ids.last }
    }

    mutating func followTail() { endID = nil }

    mutating func revealLatest() {
        endID = nil
        count = Self.batchSize
    }
}
