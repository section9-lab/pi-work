import Combine
import Foundation

/// Drafts outlive ChatView and its transcript cache. Nothing is sent or written
/// to disk merely because the user changes sessions, projects or destinations.
struct SessionComposerDraftKey: Hashable {
    let mode: String
    let projectPath: String?
    let sessionID: String?
}

struct SessionComposerDraft: Equatable {
    var text = ""
    var selectedCommand: AgentHostSlashCommand?
    var attachments: [ComposerImageAttachment] = []
    var imageProcessingID: UUID?
    fileprivate(set) var revision = UUID()
}

@MainActor
final class SessionComposerDraftStore: ObservableObject {
    @Published private var drafts: [SessionComposerDraftKey: SessionComposerDraft] = [:]
    private struct Submission {
        let id: UUID
        let draft: SessionComposerDraft
        let awaitsRunning: Bool
    }
    @Published private var submitting: [SessionComposerDraftKey: Submission] = [:]

    func isSubmitting(sessionID: String) -> Bool {
        submitting.keys.contains { $0.sessionID == sessionID }
    }

    func beginSubmission(for key: SessionComposerDraftKey, awaitsRunning: Bool = false) -> UUID? {
        guard submitting[key] == nil else { return nil }
        let id = UUID()
        submitting[key] = Submission(id: id, draft: draft(for: key), awaitsRunning: awaitsRunning)
        return id
    }

    /// ACP prompt responses arrive at the END of a turn. The running event is
    /// its acknowledgement: clear the accepted draft then, allowing follow-ups
    /// while the assistant works rather than blocking for the entire turn.
    func acceptSubmission(sessionID: String) {
        let accepted = submitting.filter { $0.key.sessionID == sessionID && $0.value.awaitsRunning }
        for (key, submission) in accepted {
            clearIfUnchanged(submission.draft, for: key)
            endSubmission(submission.id, for: key)
        }
    }

    func endSubmission(_ id: UUID, for key: SessionComposerDraftKey) {
        guard submitting[key]?.id == id else { return }
        submitting.removeValue(forKey: key)
    }

    func draft(for key: SessionComposerDraftKey) -> SessionComposerDraft {
        drafts[key] ?? SessionComposerDraft()
    }

    func set<Value: Equatable>(
        _ value: Value,
        at keyPath: WritableKeyPath<SessionComposerDraft, Value>,
        for key: SessionComposerDraftKey
    ) {
        var draft = draft(for: key)
        guard draft[keyPath: keyPath] != value else { return }
        draft[keyPath: keyPath] = value
        draft.revision = UUID()
        drafts[key] = draft
    }

    /// A response for A must not clear B, or erase edits made while A's send
    /// was in flight (including deleting and retyping exactly the same text).
    @discardableResult
    func clearIfUnchanged(_ submitted: SessionComposerDraft, for key: SessionComposerDraftKey) -> Bool {
        guard drafts[key]?.revision == submitted.revision else { return false }
        drafts.removeValue(forKey: key)
        return true
    }

    func beginImageProcessing(for key: SessionComposerDraftKey) -> UUID? {
        guard draft(for: key).imageProcessingID == nil else { return nil }
        let id = UUID()
        set(id, at: \.imageProcessingID, for: key)
        return id
    }

    /// Image work is owned by its original draft, even if that view disappeared.
    @discardableResult
    func finishImageProcessing(
        _ id: UUID,
        attachments: [ComposerImageAttachment],
        for key: SessionComposerDraftKey
    ) -> Bool {
        guard var draft = drafts[key], draft.imageProcessingID == id else { return false }
        draft.attachments.append(contentsOf: attachments)
        draft.imageProcessingID = nil
        draft.revision = UUID()
        drafts[key] = draft
        return true
    }

    func removeSession(_ sessionID: String) {
        drafts = drafts.filter { $0.key.sessionID != sessionID }
    }

    func removeProject(_ path: String) {
        drafts = drafts.filter { $0.key.mode != "work" || $0.key.projectPath != path }
    }
}
