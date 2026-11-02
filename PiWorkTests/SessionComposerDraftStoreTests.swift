import XCTest
@testable import PiWork

@MainActor
final class SessionComposerDraftStoreTests: XCTestCase {
    private func key(_ id: String?, project: String = "/project", mode: String = "work") -> SessionComposerDraftKey {
        SessionComposerDraftKey(mode: mode, projectPath: project, sessionID: id)
    }

    func testSessionsKeepIndependentTextCommandsAndImages() {
        let store = SessionComposerDraftStore()
        let a = key("a"), b = key("b")
        let command = AgentHostSlashCommand(name: "review", description: nil, source: .extensionCommand)
        let image = ComposerImageAttachment(mimeType: "image/png", data: Data([1]), pixelWidth: 1, pixelHeight: 1)
        store.set("Unsent prompt", at: \.text, for: a)
        store.set(command, at: \.selectedCommand, for: a)
        store.set([image], at: \.attachments, for: a)
        store.set("Another prompt", at: \.text, for: b)
        XCTAssertEqual(store.draft(for: a).text, "Unsent prompt")
        XCTAssertEqual(store.draft(for: a).selectedCommand, command)
        XCTAssertEqual(store.draft(for: a).attachments, [image])
        XCTAssertEqual(store.draft(for: b).text, "Another prompt")
        XCTAssertTrue(store.draft(for: b).attachments.isEmpty)
    }

    func testNewSessionDraftsAreScopedToProjectAndMode() {
        let store = SessionComposerDraftStore()
        store.set("New work draft", at: \.text, for: key(nil))
        XCTAssertTrue(store.draft(for: key(nil, project: "/other")).text.isEmpty)
        XCTAssertTrue(store.draft(for: key(nil, mode: "chat")).text.isEmpty)
        XCTAssertEqual(store.draft(for: key(nil)).text, "New work draft")
    }

    func testSendSuccessOnlyClearsItsOriginalUnchangedDraft() {
        let store = SessionComposerDraftStore()
        let a = key("a"), b = key("b")
        store.set("Send A", at: \.text, for: a)
        store.set("Keep B", at: \.text, for: b)
        let submitted = store.draft(for: a)
        XCTAssertTrue(store.clearIfUnchanged(submitted, for: a))
        XCTAssertTrue(store.draft(for: a).text.isEmpty)
        XCTAssertEqual(store.draft(for: b).text, "Keep B")
    }

    func testSendResponseDoesNotEraseEditsEvenWhenTextWasRetyped() {
        let store = SessionComposerDraftStore()
        let a = key("a")
        store.set("Same text", at: \.text, for: a)
        let submitted = store.draft(for: a)
        store.set("", at: \.text, for: a)
        store.set("Same text", at: \.text, for: a)
        XCTAssertFalse(store.clearIfUnchanged(submitted, for: a))
        XCTAssertEqual(store.draft(for: a).text, "Same text")
    }

    func testImageCompletionStaysWithItsOriginalDraft() throws {
        let store = SessionComposerDraftStore()
        let a = key("a"), b = key("b")
        let id = try XCTUnwrap(store.beginImageProcessing(for: a))
        XCTAssertNil(store.beginImageProcessing(for: a))
        store.set("Typing in B", at: \.text, for: b)
        let image = ComposerImageAttachment(mimeType: "image/png", data: Data([1, 2]), pixelWidth: 2, pixelHeight: 1)
        XCTAssertTrue(store.finishImageProcessing(id, attachments: [image], for: a))
        XCTAssertEqual(store.draft(for: a).attachments, [image])
        XCTAssertNil(store.draft(for: a).imageProcessingID)
        XCTAssertTrue(store.draft(for: b).attachments.isEmpty)
    }

    func testDeletingSessionPreventsLateImageCompletionFromResurrectingIt() throws {
        let store = SessionComposerDraftStore()
        let a = key("a")
        let id = try XCTUnwrap(store.beginImageProcessing(for: a))
        store.removeSession("a")
        XCTAssertFalse(store.finishImageProcessing(id, attachments: [], for: a))
        XCTAssertNil(store.draft(for: a).imageProcessingID)
    }

    func testSubmittingStateSurvivesViewsAndIsSessionScoped() throws {
        let store = SessionComposerDraftStore()
        let a = key("a")
        let id = try XCTUnwrap(store.beginSubmission(for: a))
        XCTAssertNil(store.beginSubmission(for: a))
        XCTAssertTrue(store.isSubmitting(sessionID: "a"))
        XCTAssertFalse(store.isSubmitting(sessionID: "b"))
        store.endSubmission(id, for: a)
        XCTAssertFalse(store.isSubmitting(sessionID: "a"))
    }

    func testRunningAcknowledgementAllowsFollowUpsWithoutOldTurnClearingNewSubmission() throws {
        let store = SessionComposerDraftStore()
        let a = key("a")
        store.set("First prompt", at: \.text, for: a)
        let first = try XCTUnwrap(store.beginSubmission(for: a, awaitsRunning: true))
        store.acceptSubmission(sessionID: "a")
        XCTAssertTrue(store.draft(for: a).text.isEmpty)
        XCTAssertFalse(store.isSubmitting(sessionID: "a"))
        store.set("Follow up", at: \.text, for: a)
        let next = try XCTUnwrap(store.beginSubmission(for: a))
        store.acceptSubmission(sessionID: "a")
        XCTAssertEqual(store.draft(for: a).text, "Follow up")
        store.endSubmission(first, for: a)
        XCTAssertTrue(store.isSubmitting(sessionID: "a"))
        store.endSubmission(next, for: a)
        XCTAssertFalse(store.isSubmitting(sessionID: "a"))
    }

    func testRemovingProjectOnlyDiscardsItsOwnDrafts() {
        let store = SessionComposerDraftStore()
        store.set("A", at: \.text, for: key("a"))
        store.set("B", at: \.text, for: key("b", project: "/other"))
        store.removeProject("/project")
        XCTAssertTrue(store.draft(for: key("a")).text.isEmpty)
        XCTAssertEqual(store.draft(for: key("b", project: "/other")).text, "B")
    }
}
