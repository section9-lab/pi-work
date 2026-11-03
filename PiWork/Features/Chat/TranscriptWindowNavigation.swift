import Foundation

/// A bounded window into visible transcript rows. An explicit end ID pins the
/// window to history while new messages arrive; nil follows the live tail.
struct TranscriptWindowNavigation: Equatable {
    static let batchSize = TranscriptWindow.batchSize
    static let maximumCount = batchSize * 3

    private(set) var count = batchSize
    private(set) var endID: String?

    func range(in ids: [String], presentationLimit: Int? = nil) -> Range<Int> {
        let end = endID.flatMap { id in ids.firstIndex(of: id).map { $0 + 1 } } ?? ids.count
        let visibleCount = min(count, max(0, presentationLimit ?? count))
        return max(0, end - visibleCount)..<end
    }

    mutating func revealEarlier(in ids: [String]) {
        let current = range(in: ids)
        guard current.lowerBound > 0 else { return }
        if endID == nil { endID = ids[current.upperBound - 1] }
        if count < Self.maximumCount {
            count = min(Self.maximumCount, count + Self.batchSize)
            return
        }
        let end = current.upperBound - min(Self.batchSize, current.lowerBound)
        endID = ids[end - 1]
    }

    mutating func revealNewer(in ids: [String]) {
        let current = range(in: ids)
        guard current.upperBound < ids.count else { return }
        let end = min(ids.count, current.upperBound + Self.batchSize)
        endID = ids[end - 1]
    }

    mutating func jump(to id: String, in ids: [String]) {
        guard let index = ids.firstIndex(of: id) else { return }
        count = Self.maximumCount
        let end = min(ids.count, index + 1 + Self.maximumCount - Self.batchSize)
        endID = ids[end - 1]
    }

    mutating func pin(in ids: [String]) {
        if endID == nil { endID = ids.last }
    }

    mutating func followTail() {
        endID = nil
    }

    mutating func revealLatest() {
        endID = nil
        count = Self.batchSize
    }
}
