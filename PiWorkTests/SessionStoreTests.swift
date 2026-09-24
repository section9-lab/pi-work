import AppKit
import SwiftUI
import XCTest
@testable import PiWork

@MainActor
final class SessionStoreTests: XCTestCase {
    func testWorkConversationFitsBesideTheWidestSidebarWithALongModelName() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(accessMode: .full))
        let store = SessionStore(service: host)
        let project = PiProject(name: "Project", path: "/tmp/project")
        let record = try await store.createDraft(
            cwd: project.path,
            sessionDirectory: nil,
            profile: .work
        )
        try await store.selectModel(
            AgentHostModel(
                provider: "anthropic",
                id: "claude-haiku-4-5",
                name: "Claude Haiku 4.5 (latest)",
                contextWindow: 200_000,
                maxTokens: 16_384,
                reasoning: true,
                supportsImages: true
            ),
            sessionId: record.id
        )
        let controller = NSHostingController(rootView: ChatView(
            mode: .work,
            projects: [project],
            selectedProject: .constant(project),
            sessionStore: store,
            onAddFolder: {}
        ))

        // A 900-point window leaves 472 points beside the 420-point sidebar and its inset.
        for width: CGFloat in [472, 632, 472] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 600))
            XCTAssertLessThanOrEqual(size.width, width, "The composer must not push the split view outside the window")
        }
        await store.stop()
    }

    func testOpenSessionEmitsEveryStorePerformanceStage() async throws {
        var events: [SessionOpenPerformanceEvent] = []
        let tracer = SessionOpenPerformanceTracer(
            nowNanoseconds: { 1_000_000_000 },
            sink: { events.append($0) }
        )
        let host = FakeAgentHost()
        let store = SessionStore(service: host, performanceTracer: tracer)
        let summary = makeSummary()
        let traceID = store.beginSessionOpenPerformanceTrace(
            sessionID: summary.id,
            profile: .work
        )

        try await store.openSession(
            summary,
            profile: .work,
            sessionDirectory: nil,
            selectSession: false,
            performanceTraceID: traceID
        )

        XCTAssertEqual(events.map(\.stage), [
            .requested,
            .hostReady,
            .openRPCCompleted,
            .snapshotCompleted,
            .projectionCompleted,
            .storePublished,
            .cacheTrimCompleted
        ])
        XCTAssertEqual(events[3].messageCount, 0)
        XCTAssertEqual(events[4].transcriptCount, 0)
        await store.stop()
    }

    func testHTMLReportDestinationUsesAUniqueSanitizedDownloadsFilename() throws {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: downloads) }
        try FileManager.default.createDirectory(
            at: downloads,
            withIntermediateDirectories: true
        )
        let summary = AgentHostSessionSummary(
            id: "01a00434-248d-7000-8000-000000000000",
            path: "/tmp/session.jsonl",
            cwd: "/tmp/project",
            title: "Planning / rollout",
            firstMessage: "",
            messageCount: 2,
            createdAt: "2026-08-15T06:30:00.000Z",
            modifiedAt: "2026-08-15T06:30:00.000Z"
        )
        let now = Date(timeIntervalSince1970: 1_776_235_800)

        let first = try SessionHTMLReportDestination.makeURL(
            for: summary,
            downloadsDirectory: downloads,
            now: now
        )
        try Data().write(to: first)
        let second = try SessionHTMLReportDestination.makeURL(
            for: summary,
            downloadsDirectory: downloads,
            now: now
        )

        XCTAssertEqual(first.deletingLastPathComponent(), downloads)
        XCTAssertEqual(
            first.lastPathComponent,
            "Planning-rollout-20260415-065000-01a00434.html"
        )
        XCTAssertEqual(
            second.lastPathComponent,
            "Planning-rollout-20260415-065000-01a00434-2.html"
        )
    }

    func testExportHTMLReportWritesIntoTheProvidedDownloadsDirectory() async throws {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: downloads) }
        let host = FakeAgentHost()
        let store = SessionStore(
            service: host,
            now: { Date(timeIntervalSince1970: 1_776_235_800) }
        )

        let reportURL = try await store.exportHTMLReport(
            makeSummary(),
            profile: .work,
            sessionDirectory: nil,
            downloadsDirectory: downloads
        )

        XCTAssertEqual(reportURL.deletingLastPathComponent(), downloads)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        let requests = await host.htmlExportRequests
        XCTAssertEqual(requests, [
            HTMLExportRequest(
                sessionId: "session-one",
                path: "/tmp/session-one.jsonl",
                sessionDirectory: nil,
                profile: .work,
                outputPath: reportURL.path
            )
        ])
        await store.stop()
    }

    func testSessionCacheEvictsOnlyOldestInactiveSessions() {
        let candidates = SessionCachePolicy.evictionCandidates(
            recency: ["oldest", "selected", "running", "older", "newest"],
            protectedSessionIDs: ["selected"],
            runningSessionIDs: ["running"],
            maximumCount: 3
        )

        XCTAssertEqual(candidates, ["oldest", "older"])
    }

    func testWorkDraftLoadsAndPersistsItsSelectedGitBranch() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(gitBranch: "main"))
        await host.setGitBranches(
            AgentHostGitBranchesResult(
                available: true,
                currentBranch: "main",
                branches: ["main", "feature/session-picker"]
            )
        )
        let store = SessionStore(service: host)

        let record = try await store.createDraft(
            cwd: "/tmp/project",
            sessionDirectory: nil,
            profile: .work
        )
        let branches = try await store.gitBranches(cwd: "/tmp/project")
        try await store.setGitBranch(
            "feature/session-picker",
            sessionId: record.id
        )

        XCTAssertEqual(branches.branches, ["main", "feature/session-picker"])
        XCTAssertEqual(store.records[record.id]?.gitBranch, "feature/session-picker")
        let selectedBranches = await host.selectedGitBranches
        XCTAssertEqual(selectedBranches, ["feature/session-picker"])
        await store.stop()
    }

    func testWorkDraftIsSelectedAndRenamedUnderItsProject() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()

        _ = try await store.createDraft(
            cwd: "/tmp/project",
            sessionDirectory: nil,
            profile: .work
        )
        _ = try await store.submitPrompt(sessionId: "session-one", text: "Fix the build")

        XCTAssertEqual(
            store.selectedWorkSessionIdByProjectPath["/tmp/project"],
            "session-one"
        )
        XCTAssertEqual(
            store.workSessionsByProjectPath["/tmp/project"]?.first?.title,
            "Fix the build"
        )
        XCTAssertEqual(store.records["session-one"]?.profile, .work)
        XCTAssertNil(store.selectedChatSessionId)
        await store.stop()
    }

    func testPromptForwardsImagesToTheAgentHost() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        let image = AgentHostPromptImage(
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )

        _ = try await store.submitPrompt(
            sessionId: "session-one",
            text: "Inspect this",
            images: [image]
        )

        let promptImages = await host.promptImages
        XCTAssertEqual(promptImages, [[image]])
        await store.stop()
    }

    func testCreateDraftSelectsAnOpenSessionWithoutCallingOpenAgain() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()

        let record = try await store.createDraft(
            cwd: "/tmp/project",
            sessionDirectory: "/tmp/sessions",
            profile: .chat
        )

        XCTAssertEqual(record.id, "session-one")
        XCTAssertEqual(store.selectedChatSessionId, "session-one")
        XCTAssertEqual(store.chatSessions, [makeSummary()])
        let openCount = await host.openCount
        XCTAssertEqual(openCount, 0)
        await store.stop()
    }

    func testOpenSessionRetriesOnceAfterTheInitialRequestTimesOut() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        await host.setOpenSessionTimeoutsRemaining(1)
        let store = SessionStore(service: host)

        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        let openCount = await host.openCount
        let requestIDs = await host.openSessionRequestIDs
        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(Set(requestIDs).count, 2)
        XCTAssertEqual(store.selectedChatSessionId, "session-one")
        XCTAssertNotNil(store.records["session-one"])
        await store.stop()
    }

    func testOpenSessionWorksWhenPrivateSnapshotIsUnavailable() async throws {
        let host = FakeAgentHost()
        await host.setSupportsPiWorkExtensions(false)
        let store = SessionStore(service: host)
        let summary = makeSummary()

        try await store.openSession(summary, profile: .chat, sessionDirectory: nil)

        let record = try XCTUnwrap(store.records[summary.id])
        XCTAssertEqual(record.descriptor.id, summary.id)
        XCTAssertEqual(record.descriptor.path, summary.path)
        XCTAssertEqual(record.descriptor.cwd, summary.cwd)
        XCTAssertEqual(record.descriptor.title, summary.title)
        XCTAssertEqual(record.messages, [])
        XCTAssertNil(record.model)
        XCTAssertEqual(record.accessMode, .none)
        let snapshotCount = await host.snapshotCount
        XCTAssertEqual(snapshotCount, 0)
        await store.stop()
    }

    func testOpenSessionWorksWhenGranularCapabilitiesOmitSnapshot() async throws {
        let host = FakeAgentHost()
        await host.setPiWorkCapabilities([.modelsList])
        let store = SessionStore(service: host)

        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        XCTAssertNotNil(store.records["session-one"])
        let snapshotCount = await host.snapshotCount
        XCTAssertEqual(snapshotCount, 0)
        await store.stop()
    }

    func testOpenSessionProjectsStandardACPStateWithoutPrivateSnapshot() async throws {
        let host = FakeAgentHost()
        await host.rejectSnapshots(true)
        await host.setACPState(makeACPState())
        let store = SessionStore(service: host)

        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)

        let record = try XCTUnwrap(store.records["session-one"])
        XCTAssertEqual(record.model?.id, "opus")
        XCTAssertEqual(record.thinkingLevel, .high)
        XCTAssertEqual(record.availableThinkingLevels, [.off, .high])
        XCTAssertEqual(record.accessMode, .ask)
        XCTAssertEqual(record.acpState.modes?.currentModeId, "ask")
        XCTAssertEqual(store.availableModels.map(\.id), ["sonnet", "opus"])
        await store.stop()
    }

    func testOpenSessionKeepsHistoryUpdatesReceivedBeforeTheLoadResponse() async throws {
        let host = FakeAgentHost()
        await host.rejectSnapshots(true)
        await host.emitDuringOpen(
            .sessionAssistantContent(
                AgentHostSessionAssistantContentPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "message-one",
                    generationIndex: 0,
                    phase: .delta,
                    contentType: .text,
                    contentIndex: 0,
                    delta: "Loaded history",
                    content: nil,
                    toolCall: nil
                )
            )
        )
        let store = SessionStore(service: host)

        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        try await waitUntil { store.records["session-one"]?.transcript.count == 1 }

        let transcript = try XCTUnwrap(store.records["session-one"]?.transcript)
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(transcript.first?.role, .assistant)
        XCTAssertEqual(transcript.first?.parts, [
            .text(
                id: "turn:message-one:assistant:0:content:0:0",
                text: "Loaded history"
            )
        ])
        await store.stop()
    }

    func testStandardAvailableCommandsAvoidThePrivateCommandRequest() async throws {
        let host = FakeAgentHost()
        await host.setSupportsPiWorkExtensions(false)
        let store = SessionStore(service: host)
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        await host.emit(
            .sessionAvailableCommandsChanged(
                AgentHostSessionAvailableCommandsChangedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    availableCommands: [
                        AgentHostACPAvailableCommand(
                            name: "review",
                            description: "Review changes"
                        )
                    ]
                )
            )
        )
        try await waitUntil {
            store.records["session-one"]?.acpState.availableCommands?.count == 1
        }

        let commands = try await store.slashCommands(sessionId: "session-one")

        XCTAssertEqual(commands.map(\.name), ["review"])
        XCTAssertEqual(commands.map(\.source), [.agent])
        let listCommandsCount = await host.listCommandsCount
        XCTAssertEqual(listCommandsCount, 0)
        await store.stop()
    }

    func testOpenSessionCanCacheHistoryWithoutChangingCurrentSelection() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)

        try await store.openSession(
            makeSummary(),
            profile: .work,
            sessionDirectory: nil,
            selectSession: false
        )

        XCTAssertNotNil(store.records["session-one"])
        XCTAssertNil(store.selectedWorkSessionIdByProjectPath["/tmp/project"])
        try store.selectOpenSession(
            sessionId: "session-one",
            profile: .work,
            cwd: "/tmp/project"
        )
        XCTAssertEqual(store.selectedWorkSessionIdByProjectPath["/tmp/project"], "session-one")
        await store.stop()
    }

    func testLoadsEarlierTranscriptPageIntoTheOpenSession() async throws {
        let host = FakeAgentHost()
        let latest = makeSessionMessage(id: "message-latest", text: "Latest")
        let earlier = makeSessionMessage(id: "message-earlier", text: "Earlier")
        await host.setSnapshot(makeStoreSnapshot(
            messages: [latest],
            history: AgentHostSessionHistory(
                revision: "revision-one",
                nextCursor: "cursor-one",
                hasMore: true
            )
        ))
        await host.setTranscriptPage(AgentHostSessionTranscriptPageResult(
            sessionId: "session-one",
            messages: [earlier],
            revision: "revision-one",
            nextCursor: nil,
            hasMore: false
        ))
        let store = SessionStore(service: host)
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        let loadedCount = try await store.loadEarlierMessages(sessionId: "session-one")

        XCTAssertEqual(loadedCount, 1)
        XCTAssertEqual(
            store.records["session-one"]?.messages.map(\.id),
            ["message-earlier", "message-latest"]
        )
        XCTAssertEqual(
            store.records["session-one"]?.transcript.map(\.id),
            ["message-earlier", "message-latest"]
        )
        XCTAssertNil(store.records["session-one"]?.historyCursor)
        XCTAssertEqual(store.records["session-one"]?.hasEarlierMessages, false)
        let transcriptPageCount = await host.transcriptPageCount
        XCTAssertEqual(transcriptPageCount, 1)
        await store.stop()
    }

    func testLoadsFullToolOutputOnlyWhenRequested() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)

        let output = try await store.toolOutput(
            sessionId: "session-one",
            toolCallId: "tool-one"
        )

        XCTAssertEqual(output, "full output")
        await store.stop()
    }

    func testScheduledDraftCanBeCreatedWithoutChangingSelection() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()

        let record = try await store.createDraft(
            cwd: "/tmp/project",
            sessionDirectory: nil,
            profile: .work,
            selectSession: false
        )

        XCTAssertEqual(record.id, "session-one")
        XCTAssertNil(store.selectedWorkSessionIdByProjectPath["/tmp/project"])
        XCTAssertEqual(store.workSessionsByProjectPath["/tmp/project"], [makeSummary()])
        await store.stop()
    }

    func testScheduledPromptWaitsForAgentCompletionWithoutChangingSelection() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()

        let execution = Task { @MainActor in
            try await store.runScheduledPrompt(
                cwd: "/tmp/project",
                instruction: "Analyze this project",
                accessMode: .readOnly
            )
        }
        try await waitUntil { await host.promptTexts == ["Analyze this project"] }
        await host.emit(
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "scheduled-turn",
                    state: .running
                )
            )
        )
        await host.emit(
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "scheduled-turn",
                    state: .idle
                )
            )
        )

        let executionResult = try await execution.value

        XCTAssertEqual(executionResult.sessionID, "session-one")
        XCTAssertNil(executionResult.resultText)
        XCTAssertNil(store.selectedWorkSessionIdByProjectPath["/tmp/project"])
        let selectedAccessModes = await host.selectedAccessModes
        XCTAssertEqual(selectedAccessModes, [.readOnly])
        await store.stop()
    }

    func testAbortStaysStoppingUntilTheHostEmitsIdle() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        await host.emit(
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    state: .running
                )
            )
        )
        try await waitUntil { store.records["session-one"]?.runState == .running }

        try await store.abortSession(sessionId: "session-one")

        XCTAssertEqual(store.records["session-one"]?.runState, .stopping)
        let abortCount = await host.abortCount
        XCTAssertEqual(abortCount, 1)

        await host.emit(
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    state: .idle
                )
            )
        )
        try await waitUntil { store.records["session-one"]?.runState == .idle }
        await store.stop()
    }

    func testModelSelectionUpdatesTheOpenSession() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        try await store.selectModel(makeModel(), sessionId: "session-one")

        XCTAssertEqual(store.records["session-one"]?.model, makeModel())
        let selectedModelIds = await host.selectedModelIds
        XCTAssertEqual(selectedModelIds, ["gpt-test"])
        await store.stop()
    }

    func testThinkingLevelSelectionUpdatesTheOpenSession() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        try await store.selectThinkingLevel(.max, sessionId: "session-one")

        XCTAssertEqual(store.records["session-one"]?.thinkingLevel, .max)
        let selectedThinkingLevels = await host.selectedThinkingLevels
        XCTAssertEqual(selectedThinkingLevels, [.max])
        await store.stop()
    }

    func testModelOptionSelectionUpdatesTheOpenSession() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        try await store.selectModelOption(
            .fastMode,
            enabled: true,
            sessionId: "session-one"
        )

        XCTAssertEqual(store.records["session-one"]?.modelOptions.fastMode.enabled, true)
        let selectedOptions = await host.selectedModelOptions
        XCTAssertEqual(
            selectedOptions,
            [ModelOptionSelection(option: .fastMode, enabled: true)]
        )
        await store.stop()
    }

    func testAccessModeSelectionUpdatesTheOpenWorkSession() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(accessMode: .ask))
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)

        try await store.selectAccessMode(.full, sessionId: "session-one")

        XCTAssertEqual(store.records["session-one"]?.accessMode, .full)
        let selectedAccessModes = await host.selectedAccessModes
        XCTAssertEqual(selectedAccessModes, [.full])
        await store.stop()
    }

    func testApprovalRequestCanBeAllowedOnce() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(accessMode: .ask))
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)

        await host.emit(
            .sessionApprovalRequested(
                AgentHostSessionApprovalRequestedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    requestId: "approval-one",
                    toolCallId: "tool-one",
                    toolName: "write",
                    summary: #"{"path":"Sources/App.swift"}"#
                )
            )
        )
        try await waitUntil {
            store.records["session-one"]?.pendingApprovals.count == 1
        }

        try await store.resolveApproval(
            sessionId: "session-one",
            requestId: "approval-one",
            decision: .allowOnce
        )

        XCTAssertEqual(store.records["session-one"]?.pendingApprovals, [])
        let resolutions = await host.approvalResolutions
        XCTAssertEqual(
            resolutions,
            [ApprovalResolution(requestId: "approval-one", decision: .allowOnce)]
        )
        await store.stop()
    }

    func testElicitationRequestCanBeAccepted() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(accessMode: .ask))
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
        let request = AgentHostACPElicitationRequest(
            id: "elicitation-one",
            sessionId: "session-one",
            message: "Choose",
            schema: AgentHostACPElicitationSchema(
                properties: ["value": .init(type: .string)],
                required: ["value"]
            )
        )
        await host.emit(.elicitationRequested(request))
        try await waitUntil {
            store.records["session-one"]?.pendingElicitations == [request]
        }

        try await store.resolveElicitation(
            sessionId: "session-one",
            requestId: request.id,
            response: .accept(["value": .string("Run")])
        )

        XCTAssertEqual(store.records["session-one"]?.pendingElicitations, [])
        let resolutions = await host.elicitationResolutions
        XCTAssertEqual(
            resolutions,
            [
                ElicitationResolution(
                    requestId: request.id,
                    response: .accept(["value": .string("Run")])
                )
            ]
        )
        await store.stop()
    }

    func testRequestScopedElicitationIsPresentedWithoutAnOpenSession() async throws {
        let host = FakeAgentHost()
        let store = SessionStore(service: host)
        try await store.start()
        let request = AgentHostACPElicitationRequest(
            id: "elicitation-global",
            requestId: "request-one",
            message: "Authenticate",
            schema: AgentHostACPElicitationSchema(properties: [:])
        )

        await host.emit(.elicitationRequested(request))
        try await waitUntil { store.pendingElicitations == [request] }

        try await store.resolveElicitation(
            sessionId: nil,
            requestId: request.id,
            response: .decline
        )

        XCTAssertEqual(store.pendingElicitations, [])
        let resolutions = await host.elicitationResolutions
        XCTAssertEqual(
            resolutions,
            [ElicitationResolution(requestId: request.id, response: .decline)]
        )
        await store.stop()
    }

    func testChangingAccessModeClearsAnApprovalThatWasWaiting() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(accessMode: .ask))
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
        await host.emit(
            .sessionApprovalRequested(
                AgentHostSessionApprovalRequestedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    requestId: "approval-one",
                    toolCallId: "tool-one",
                    toolName: "bash",
                    summary: "bun test"
                )
            )
        )
        try await waitUntil {
            store.records["session-one"]?.pendingApprovals.count == 1
        }

        try await store.selectAccessMode(.full, sessionId: "session-one")

        XCTAssertEqual(store.records["session-one"]?.pendingApprovals, [])
        await store.stop()
    }

    func testRestartRestoresTheSelectedWorkAccessMode() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(accessMode: .ask))
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
        try await store.selectAccessMode(.full, sessionId: "session-one")

        await host.emitLifecycle(
            .restarted(
                generation: 2,
                hello: AgentHostHelloPayload(
                    hostVersion: "test-host",
                    piVersion: "0.83.0",
                    capabilities: [],
                    supportsPiWorkExtensions: true
                )
            )
        )
        try await waitUntil { await host.openCount == 2 }
        try await waitUntil { await host.selectedAccessModes.count == 2 }

        XCTAssertEqual(store.records["session-one"]?.accessMode, .full)
        let selectedAccessModes = await host.selectedAccessModes
        XCTAssertEqual(selectedAccessModes, [.full, .full])
        await store.stop()
    }

    func testCloseReleasesTheOpenRecordButKeepsItsSidebarSummary() async throws {
        let host = FakeAgentHost()
        await host.setSessions([makeSummary()])
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.bootstrap(cwd: "/tmp/project", sessionDirectory: nil, profile: .chat)
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        try await store.closeSession(sessionId: "session-one")

        XCTAssertNil(store.records["session-one"])
        XCTAssertNil(store.selectedChatSessionId)
        XCTAssertEqual(store.chatSessions, [makeSummary()])
        let closeCount = await host.closeCount
        XCTAssertEqual(closeCount, 1)
        await store.stop()
    }

    func testDeleteRemovesTheWorkSessionFromItsProject() async throws {
        let summary = makeSummary()
        let host = FakeAgentHost()
        await host.setSessions([summary])
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.bootstrap(cwd: summary.cwd, sessionDirectory: nil, profile: .work)
        try await store.openSession(summary, profile: .work, sessionDirectory: nil)

        try await store.deleteSession(summary, profile: .work, sessionDirectory: nil)

        XCTAssertEqual(store.workSessionsByProjectPath[summary.cwd], [])
        XCTAssertNil(store.selectedWorkSessionIdByProjectPath[summary.cwd])
        XCTAssertNil(store.records[summary.id])
        let deleteCount = await host.deleteCount
        XCTAssertEqual(deleteCount, 1)
        await store.stop()
    }

    func testDeleteWorkSessionsListsAndDeletesEverySessionForProject() async throws {
        let first = makeSummary(id: "session-one")
        let second = makeSummary(id: "session-two")
        let host = FakeAgentHost()
        await host.setSessions([first, second])
        let store = SessionStore(service: host)

        try await store.deleteWorkSessions(cwd: first.cwd, sessionDirectory: nil)

        XCTAssertNil(store.workSessionsByProjectPath[first.cwd])
        XCTAssertNil(store.selectedWorkSessionIdByProjectPath[first.cwd])
        let deletedSessionIds = await host.deletedSessionIds
        XCTAssertEqual(deletedSessionIds, [first.id, second.id])
        await store.stop()
    }

    func testSelectingAnAlreadyOpenSessionDoesNotOpenASecondHandle() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        let store = SessionStore(service: host)
        try await store.start()

        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        let openCount = await host.openCount
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(store.selectedChatSessionId, "session-one")
        await store.stop()
    }

    func testRejectedPromptLeavesTheUserMessageAndMarksTheSessionFailed() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        await host.rejectPrompts(true)
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        do {
            _ = try await store.submitPrompt(sessionId: "session-one", text: "Hello")
            XCTFail("Expected prompt rejection")
        } catch FakeAgentHostError.promptRejected {
            // Expected.
        }

        XCTAssertEqual(store.records["session-one"]?.runState, .failed)
        XCTAssertEqual(store.records["session-one"]?.messages.last?.content, [.text("Hello")])
        XCTAssertEqual(store.records["session-one"]?.descriptor.title, "New Session")
        XCTAssertNil(store.records["session-one"]?.activeTurnId)
        let promptTexts = await host.promptTexts
        XCTAssertEqual(promptTexts, ["Hello"])
        await store.stop()
    }

    func testBootstrapLoadsChatSessionsAndAvailableModels() async throws {
        let host = FakeAgentHost()
        await host.setSessions([makeSummary()])
        await host.setModels([makeModel()])
        let store = SessionStore(service: host)

        try await store.bootstrap(
            cwd: "/tmp/project",
            sessionDirectory: "/tmp/sessions",
            profile: .chat
        )

        XCTAssertEqual(store.chatSessions, [makeSummary()])
        XCTAssertEqual(store.availableModels, [makeModel()])
        let startCount = await host.startCount
        XCTAssertEqual(startCount, 1)
        await store.stop()
    }

    func testAuthenticationModelChangeReloadsAvailableModels() async throws {
        let host = FakeAgentHost()
        await host.setModels([makeModel()])
        let store = SessionStore(service: host)
        try await store.bootstrap(
            cwd: "/tmp/project",
            sessionDirectory: nil,
            profile: .chat
        )
        await host.setModels([])

        await host.emit(
            .modelsChanged(
                AgentHostModelsChangedPayload(
                    reason: .authentication,
                    providerId: "openai"
                )
            )
        )

        try await waitUntil { store.availableModels.isEmpty }
        let listModelsCount = await host.listModelsCount
        XCTAssertEqual(listModelsCount, 2)
        await store.stop()
    }

    func testBootstrapSortsSessionsByMostRecentlyModified() async throws {
        let older = makeSummary(id: "older", modifiedAt: "2026-08-08T00:00:00.000Z")
        let newer = makeSummary(id: "newer", modifiedAt: "2026-08-09T00:00:00.000Z")
        let host = FakeAgentHost()
        await host.setSessions([older, newer])
        let store = SessionStore(service: host)

        try await store.bootstrap(cwd: "/tmp/project", sessionDirectory: nil, profile: .chat)

        XCTAssertEqual(store.chatSessions.map(\.id), ["newer", "older"])
        await store.stop()
    }

    func testBootstrapWorksWhenPrivateModelCatalogIsUnavailable() async throws {
        let host = FakeAgentHost()
        await host.setSessions([makeSummary()])
        await host.setSupportsPiWorkExtensions(false)
        let store = SessionStore(service: host)

        try await store.bootstrap(cwd: "/tmp/project", sessionDirectory: nil, profile: .chat)

        XCTAssertEqual(store.chatSessions, [makeSummary()])
        XCTAssertEqual(store.availableModels, [])
        let listModelsCount = await host.listModelsCount
        XCTAssertEqual(listModelsCount, 0)
        await store.stop()
    }

    func testPromptCompletionWinsOverAnEarlierRunningEvent() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot())
        await host.emitRunningBeforePromptResponse(true)
        let store = SessionStore(
            service: host,
            now: { Date(timeIntervalSince1970: 1_786_233_601) }
        )
        try await store.start()
        try await store.openSession(
            makeSummary(),
            profile: .chat,
            sessionDirectory: "/tmp/sessions"
        )

        _ = try await store.submitPrompt(
            sessionId: "session-one",
            text: "Build the feature"
        )

        XCTAssertEqual(store.records["session-one"]?.runState, .idle)
        XCTAssertNil(store.records["session-one"]?.activeTurnId)
        XCTAssertEqual(store.records["session-one"]?.descriptor.title, "Build the feature")
        let promptTexts = await host.promptTexts
        let renamedTitles = await host.renamedTitles
        XCTAssertEqual(promptTexts, ["Build the feature"])
        XCTAssertEqual(renamedTitles, ["Build the feature"])
        await store.stop()
    }

    func testSequenceGapRequestsAndAppliesARepairSnapshot() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(sequence: 0))
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        await host.setSnapshot(makeStoreSnapshot(sequence: 2))

        await host.emit(
            .sessionMessageDelta(
                AgentHostSessionMessageDeltaPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    delta: "missed sequence one"
                )
            )
        )
        try await waitUntil { store.records["session-one"]?.lastSequence == 2 }

        let snapshotCount = await host.snapshotCount
        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(store.records["session-one"]?.lastSequence, 2)
        await store.stop()
    }

    func testRestartReopensAndSnapshotsTheSelectedSession() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(sequence: 0))
        let store = SessionStore(service: host)
        try await store.start()
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)

        await host.emitLifecycle(
            .restarted(
                generation: 2,
                hello: AgentHostHelloPayload(
                    hostVersion: "test-host",
                    piVersion: "0.83.0",
                    capabilities: [],
                    supportsPiWorkExtensions: true
                )
            )
        )
        try await waitUntil { await host.openCount == 2 }

        let openCount = await host.openCount
        let snapshotCount = await host.snapshotCount
        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(snapshotCount, 2)
        await store.stop()
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Timed out waiting for SessionStore state")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor FakeAgentHost: AgentHostServicing {
    private var serverEventContinuation: AsyncStream<AgentHostServerEvent>.Continuation!
    private var lifecycleContinuation: AsyncStream<AgentHostServiceLifecycleEvent>.Continuation!
    private let serverEvents: AsyncStream<AgentHostServerEvent>
    private let lifecycles: AsyncStream<AgentHostServiceLifecycleEvent>
    private var sessions: [AgentHostSessionSummary] = []
    private var models: [AgentHostModel] = []
    private var snapshotResult = makeStoreSnapshot()
    private var transcriptPageResult = AgentHostSessionTranscriptPageResult(
        sessionId: "session-one",
        messages: [],
        revision: "test-revision",
        nextCursor: nil,
        hasMore: false
    )
    private var gitBranchesResult = AgentHostGitBranchesResult.unavailable
    private var shouldEmitRunningBeforeResponse = false
    private var shouldRejectPrompts = false
    private var shouldRejectSnapshots = false
    private var shouldRejectModelCatalog = false
    private var openSessionTimeoutsRemaining = 0
    private var acpState = AgentHostACPSessionState.empty
    private var eventDuringOpen: AgentHostServerEvent?
    private var piWorkCapabilities = AgentHostPiWorkCapability.all

    private(set) var startCount = 0
    private(set) var openCount = 0
    private(set) var openSessionRequestIDs: [String] = []
    private(set) var snapshotCount = 0
    private(set) var transcriptPageCount = 0
    private(set) var promptTexts: [String] = []
    private(set) var promptImages: [[AgentHostPromptImage]] = []
    private(set) var renamedTitles: [String] = []
    private(set) var selectedModelIds: [String] = []
    private(set) var selectedThinkingLevels: [AgentHostThinkingLevel] = []
    private(set) var selectedModelOptions: [ModelOptionSelection] = []
    private(set) var selectedAccessModes: [AgentHostAccessMode] = []
    private(set) var approvalResolutions: [ApprovalResolution] = []
    private(set) var elicitationResolutions: [ElicitationResolution] = []
    private(set) var abortCount = 0
    private(set) var closeCount = 0
    private(set) var deleteCount = 0
    private(set) var deletedSessionIds: [String] = []
    private(set) var listModelsCount = 0
    private(set) var selectedGitBranches: [String] = []
    private(set) var htmlExportRequests: [HTMLExportRequest] = []
    private(set) var listCommandsCount = 0

    init() {
        var eventContinuation: AsyncStream<AgentHostServerEvent>.Continuation!
        serverEvents = AsyncStream { eventContinuation = $0 }
        serverEventContinuation = eventContinuation
        var connectionContinuation: AsyncStream<AgentHostServiceLifecycleEvent>.Continuation!
        lifecycles = AsyncStream { connectionContinuation = $0 }
        lifecycleContinuation = connectionContinuation
    }

    func setSessions(_ sessions: [AgentHostSessionSummary]) {
        self.sessions = sessions
    }

    func setModels(_ models: [AgentHostModel]) {
        self.models = models
    }

    func setSnapshot(_ snapshot: AgentHostSessionSnapshotResult) {
        snapshotResult = snapshot
    }

    func setACPState(_ state: AgentHostACPSessionState) {
        acpState = state
    }

    func emitDuringOpen(_ event: AgentHostServerEvent?) {
        eventDuringOpen = event
    }

    func rejectSnapshots(_ enabled: Bool) {
        shouldRejectSnapshots = enabled
    }

    func rejectModelCatalog(_ enabled: Bool) {
        shouldRejectModelCatalog = enabled
    }

    func setSupportsPiWorkExtensions(_ enabled: Bool) {
        piWorkCapabilities = enabled ? AgentHostPiWorkCapability.all : []
    }

    func setPiWorkCapabilities(_ capabilities: Set<AgentHostPiWorkCapability>) {
        piWorkCapabilities = capabilities
    }

    func setTranscriptPage(_ page: AgentHostSessionTranscriptPageResult) {
        transcriptPageResult = page
    }

    func setGitBranches(_ result: AgentHostGitBranchesResult) {
        gitBranchesResult = result
    }

    func emitRunningBeforePromptResponse(_ enabled: Bool) {
        shouldEmitRunningBeforeResponse = enabled
    }

    func rejectPrompts(_ enabled: Bool) {
        shouldRejectPrompts = enabled
    }

    func setOpenSessionTimeoutsRemaining(_ count: Int) {
        openSessionTimeoutsRemaining = count
    }

    func emit(_ event: AgentHostServerEvent) {
        serverEventContinuation.yield(event)
    }

    func emitLifecycle(_ event: AgentHostServiceLifecycleEvent) {
        lifecycleContinuation.yield(event)
    }

    func events() -> AsyncStream<AgentHostServerEvent> {
        serverEvents
    }

    func lifecycleEvents() -> AsyncStream<AgentHostServiceLifecycleEvent> {
        lifecycles
    }

    func start() async throws -> AgentHostHelloPayload {
        startCount += 1
        let hello = AgentHostHelloPayload(
            hostVersion: "test-host",
            piVersion: "0.83.0",
            capabilities: [],
            piWorkCapabilities: piWorkCapabilities
        )
        lifecycleContinuation.yield(.connected(generation: 1, hello: hello))
        return hello
    }

    func stop() async {
        serverEventContinuation.finish()
        lifecycleContinuation.finish()
    }

    func listSessions(
        cwd: String,
        sessionDirectory: String?,
        requestID: String
    ) async throws -> [AgentHostSessionSummary] {
        sessions
    }

    func listModels(requestID: String) async throws -> [AgentHostModel] {
        listModelsCount += 1
        if shouldRejectModelCatalog {
            throw AgentHostClientError.requestFailed(
                code: "-32601",
                message: "Method not found"
            )
        }
        return models
    }

    func gitBranches(
        cwd: String,
        requestID: String
    ) async throws -> AgentHostGitBranchesResult {
        gitBranchesResult
    }

    func createDraft(
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        requestID: String
    ) async throws -> AgentHostSessionCreateDraftResult {
        AgentHostSessionCreateDraftResult(
            session: makeSummary(),
            acpState: acpState
        )
    }

    func openSession(
        sessionId: String,
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        requestID: String
    ) async throws -> AgentHostSessionOpenResult {
        openCount += 1
        openSessionRequestIDs.append(requestID)
        if openSessionTimeoutsRemaining > 0 {
            openSessionTimeoutsRemaining -= 1
            throw AgentHostClientError.requestTimedOut(requestID)
        }
        if let eventDuringOpen {
            serverEventContinuation.yield(eventDuringOpen)
            await Task.yield()
        }
        return AgentHostSessionOpenResult(
            sessionId: sessionId,
            path: sessionId,
            cwd: cwd,
            acpState: acpState
        )
    }

    func exportHTML(
        sessionId: String,
        path: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        outputPath: String,
        requestID: String
    ) async throws -> AgentHostSessionExportHTMLResult {
        htmlExportRequests.append(
            HTMLExportRequest(
                sessionId: sessionId,
                path: path,
                sessionDirectory: sessionDirectory,
                profile: profile,
                outputPath: outputPath
            )
        )
        try Data("<!DOCTYPE html>".utf8).write(to: URL(fileURLWithPath: outputPath))
        return AgentHostSessionExportHTMLResult(sessionId: sessionId, path: outputPath)
    }

    func snapshot(
        sessionId: String,
        requestID: String
    ) async throws -> AgentHostSessionSnapshotResult {
        snapshotCount += 1
        if shouldRejectSnapshots {
            throw AgentHostClientError.requestFailed(
                code: "-32601",
                message: "Method not found"
            )
        }
        return snapshotResult
    }

    func transcriptPage(
        sessionId: String,
        cursor: String,
        limit: Int,
        requestID: String
    ) async throws -> AgentHostSessionTranscriptPageResult {
        transcriptPageCount += 1
        return transcriptPageResult
    }

    func toolOutput(
        sessionId: String,
        toolCallId: String,
        requestID: String
    ) async throws -> AgentHostSessionToolOutputResult {
        AgentHostSessionToolOutputResult(
            sessionId: sessionId,
            toolCallId: toolCallId,
            output: "full output"
        )
    }

    func listSlashCommands(
        sessionId: String,
        requestID: String
    ) async throws -> [AgentHostSlashCommand] {
        listCommandsCount += 1
        return []
    }

    func setGitBranch(
        sessionId: String,
        branch: String,
        requestID: String
    ) async throws -> AgentHostSessionSetGitBranchResult {
        selectedGitBranches.append(branch)
        return AgentHostSessionSetGitBranchResult(sessionId: sessionId, branch: branch)
    }

    func renameSession(
        sessionId: String,
        title: String,
        requestID: String
    ) async throws -> AgentHostSessionRenameResult {
        renamedTitles.append(title)
        return AgentHostSessionRenameResult(sessionId: sessionId, title: title)
    }

    func setModel(
        sessionId: String,
        provider: String,
        modelId: String,
        requestID: String
    ) async throws -> AgentHostSessionSetModelResult {
        selectedModelIds.append(modelId)
        return AgentHostSessionSetModelResult(
            sessionId: sessionId,
            model: makeModel(),
            thinkingLevel: .high,
            availableThinkingLevels: [.off, .low, .medium, .high, .max]
        )
    }

    func setThinkingLevel(
        sessionId: String,
        thinkingLevel: AgentHostThinkingLevel,
        requestID: String
    ) async throws -> AgentHostSessionSetThinkingLevelResult {
        selectedThinkingLevels.append(thinkingLevel)
        return AgentHostSessionSetThinkingLevelResult(
            sessionId: sessionId,
            thinkingLevel: thinkingLevel,
            availableThinkingLevels: snapshotResult.availableThinkingLevels
        )
    }

    func setModelOption(
        sessionId: String,
        option: AgentHostModelOption,
        enabled: Bool,
        requestID: String
    ) async throws -> AgentHostSessionSetModelOptionResult {
        selectedModelOptions.append(
            ModelOptionSelection(option: option, enabled: enabled)
        )
        return AgentHostSessionSetModelOptionResult(
            sessionId: sessionId,
            model: makeModel(),
            contextUsage: nil,
            modelOptions: AgentHostModelOptions(
                fastMode: AgentHostModelOptionState(
                    supported: true,
                    enabled: option == .fastMode && enabled
                ),
                oneMillionContext: AgentHostModelOptionState(
                    supported: false,
                    enabled: false
                )
            )
        )
    }

    func setAccessMode(
        sessionId: String,
        accessMode: AgentHostAccessMode,
        requestID: String
    ) async throws -> AgentHostSessionSetAccessModeResult {
        selectedAccessModes.append(accessMode)
        snapshotResult = makeStoreSnapshot(
            sequence: snapshotResult.sequence,
            accessMode: accessMode,
            pendingApprovals: snapshotResult.pendingApprovals
        )
        return AgentHostSessionSetAccessModeResult(
            sessionId: sessionId,
            accessMode: accessMode
        )
    }

    func resolveApproval(
        sessionId: String,
        requestId: String,
        decision: AgentHostApprovalDecision,
        requestID: String
    ) async throws -> AgentHostSessionResolveApprovalResult {
        approvalResolutions.append(
            ApprovalResolution(requestId: requestId, decision: decision)
        )
        return AgentHostSessionResolveApprovalResult(
            sessionId: sessionId,
            requestId: requestId,
            decision: decision
        )
    }

    func resolveElicitation(
        sessionId: String?,
        requestId: String,
        response: AgentHostACPElicitationResponse,
        requestID: String
    ) async throws {
        elicitationResolutions.append(
            ElicitationResolution(requestId: requestId, response: response)
        )
    }

    func prompt(
        sessionId: String,
        turnId: String,
        text: String,
        images: [AgentHostPromptImage],
        requestID: String
    ) async throws -> AgentHostSessionPromptResult {
        promptTexts.append(text)
        promptImages.append(images)
        if shouldRejectPrompts {
            throw FakeAgentHostError.promptRejected
        }
        if shouldEmitRunningBeforeResponse {
            serverEventContinuation.yield(
                .sessionStateChanged(
                    AgentHostSessionStateChangedPayload(
                        sessionId: sessionId,
                        sequence: 1,
                        turnId: turnId,
                        state: .running
                    )
                )
            )
            await Task.yield()
        }
        return AgentHostSessionPromptResult(
            accepted: true,
            sessionId: sessionId,
            turnId: turnId
        )
    }

    func abort(
        sessionId: String,
        requestID: String
    ) async throws -> AgentHostSessionAbortResult {
        abortCount += 1
        return AgentHostSessionAbortResult(aborted: true, sessionId: sessionId)
    }

    func closeSession(
        sessionId: String,
        requestID: String
    ) async throws -> AgentHostSessionCloseResult {
        closeCount += 1
        return AgentHostSessionCloseResult(closed: true, sessionId: sessionId)
    }

    func deleteSession(
        sessionId: String,
        cwd: String,
        sessionDirectory: String?,
        requestID: String
    ) async throws -> AgentHostSessionDeleteResult {
        deleteCount += 1
        deletedSessionIds.append(sessionId)
        return AgentHostSessionDeleteResult(deleted: true, sessionId: sessionId)
    }
}

private enum FakeAgentHostError: Error {
    case promptRejected
}

private struct HTMLExportRequest: Equatable {
    let sessionId: String
    let path: String
    let sessionDirectory: String?
    let profile: AgentHostSessionProfile
    let outputPath: String
}

private struct ApprovalResolution: Equatable {
    let requestId: String
    let decision: AgentHostApprovalDecision
}

private struct ElicitationResolution: Equatable {
    let requestId: String
    let response: AgentHostACPElicitationResponse
}

private struct ModelOptionSelection: Equatable {
    let option: AgentHostModelOption
    let enabled: Bool
}

private func makeSummary(
    id: String = "session-one",
    modifiedAt: String = "2026-08-09T00:00:00.000Z"
) -> AgentHostSessionSummary {
    AgentHostSessionSummary(
        id: id,
        path: "/tmp/\(id).jsonl",
        cwd: "/tmp/project",
        title: "New Session",
        firstMessage: "",
        messageCount: 0,
        createdAt: "2026-08-09T00:00:00.000Z",
        modifiedAt: modifiedAt
    )
}

private func makeACPState() -> AgentHostACPSessionState {
    AgentHostACPSessionState(
        modes: AgentHostACPSessionModeState(
            currentModeId: "ask",
            availableModes: [
                AgentHostACPSessionMode(id: "ask", name: "Ask", description: nil)
            ]
        ),
        configOptions: [
            AgentHostACPSetConfigOptionResult.ConfigOption(
                id: "agent-model",
                name: "Model",
                category: "model",
                type: "select",
                currentValue: .string("opus"),
                options: [
                    .init(value: "sonnet", name: "Sonnet"),
                    .init(value: "opus", name: "Opus")
                ]
            ),
            AgentHostACPSetConfigOptionResult.ConfigOption(
                id: "reasoning",
                name: "Thinking",
                category: "thought_level",
                type: "select",
                currentValue: .string("high"),
                options: [
                    .init(value: "off", name: "Off"),
                    .init(value: "high", name: "High")
                ]
            )
        ]
    )
}

private func makeModel() -> AgentHostModel {
    AgentHostModel(
        provider: "openai",
        id: "gpt-test",
        name: "GPT Test",
        contextWindow: 128_000,
        maxTokens: 16_384,
        reasoning: true,
        supportsImages: true
    )
}

private func makeStoreSnapshot(
    sequence: Int = 0,
    gitBranch: String? = nil,
    accessMode: AgentHostAccessMode = .none,
    pendingApprovals: [AgentHostApprovalRequest] = [],
    messages: [AgentHostSessionMessage] = [],
    history: AgentHostSessionHistory? = nil
) -> AgentHostSessionSnapshotResult {
    AgentHostSessionSnapshotResult(
        session: AgentHostSessionDescriptor(
            id: "session-one",
            path: "/tmp/session-one.jsonl",
            cwd: "/tmp/project",
            title: "New Session"
        ),
        messages: messages,
        history: history,
        state: .idle,
        sequence: sequence,
        turnId: nil,
        gitBranch: gitBranch,
        model: nil,
        thinkingLevel: .high,
        availableThinkingLevels: [.off, .low, .medium, .high, .max],
        accessMode: accessMode,
        pendingApprovals: pendingApprovals
    )
}

private func makeSessionMessage(id: String, text: String) -> AgentHostSessionMessage {
    AgentHostSessionMessage(
        id: id,
        role: .user,
        content: [.text(text)],
        timestamp: "2026-08-09T00:00:00.000Z",
        provider: nil,
        model: nil,
        stopReason: nil,
        errorMessage: nil,
        toolCallId: nil,
        toolName: nil,
        isError: nil
    )
}
