import Foundation

/// Content notifications never imply that data was dropped: recordsPublisher and
/// recordUpdates still publish every committed snapshot. Only the view's window
/// projection may ignore these narrowly classified changes.
struct SessionTranscriptUpdate {
    let structuralSessionIDs: Set<String>
    let contentMessageIDs: [String: Set<String>]

    static let empty = SessionTranscriptUpdate(structuralSessionIDs: [], contentMessageIDs: [:])
}

/// The exact destination matters. A late delta for generation 0 must not be
/// mistaken for a local update of the currently visible generation 1.
struct SessionTextUpdateIdentity {
    let sessionID: String
    let sequence: Int
    let turnID: String
    let messageID: String
    let partID: String

    init?(_ event: AgentHostServerEvent) {
        switch event {
        case .sessionMessageDelta(let value):
            sessionID = value.sessionId; sequence = value.sequence; turnID = value.turnId
            messageID = "turn:\(value.turnId):assistant"
            partID = "\(messageID):text:0"
        case .sessionAssistantContent(let value) where value.phase == .delta && value.contentType == .text:
            sessionID = value.sessionId; sequence = value.sequence; turnID = value.turnId
            messageID = "turn:\(value.turnId):assistant:\(value.generationIndex)"
            partID = "\(messageID):content:\(value.generationIndex):\(value.contentIndex)"
        default: return nil
        }
    }

    /// O(1), with no retained record/array across reducer mutation. First content,
    /// added blocks, non-text parts, other generations, and terminal events all
    /// take the normal structural route. A running text row is already visible,
    /// including whitespace prefixes, so append-only text cannot alter membership.
    func matches(_ record: SessionRecord?, sequence expectedSequence: Int) -> Bool {
        guard let record, record.lastSequence == expectedSequence,
              record.runState == .running, record.activeTurnId == turnID,
              let last = record.transcript.last, last.id == messageID, last.role == .assistant,
              last.compaction == nil, last.parts.count == 1,
              case .text(let id, _) = last.parts[0], id == partID else { return false }
        return true
    }
}

extension SessionRecord {
    var isExecutingTurn: Bool {
        switch runState {
        case .submitting, .running, .stopping: return true
        default: return false
        }
    }

    var streamingTranscriptMessageID: String? {
        guard isExecutingTurn, let turn = activeTurnId else { return nil }
        let prefix = "turn:\(turn):assistant"
        return transcript.last { $0.role == .assistant && ($0.id == prefix || $0.id.hasPrefix(prefix + ":")) }?.id
    }
}
