import AppKit
import Combine
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
            composerDrafts: SessionComposerDraftStore(),
            onAddFolder: {}
        ))

        // A 900-point window leaves 472 points beside the 420-point sidebar and its inset.
        for width: CGFloat in [472, 632, 472] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 600))
            XCTAssertLessThanOrEqual(size.width, width, "The composer must not push the split view outside the window")
        }
        await store.stop()
    }

    func testPromptRailRemainsVisibleInActualConversationWhenResizingBelowOldWidthThreshold() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(messages: (1...5).map {
            makeSessionMessage(id: "prompt-\($0)", text: "User question \($0)")
        }))
        let store = SessionStore(service: host)
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
        let controller = NSHostingController(rootView: ChatView(
            mode: .work,
            projects: [],
            selectedProject: .constant(PiProject(name: "Project", path: "/tmp/project")),
            sessionStore: store,
            composerDrafts: SessionComposerDraftStore(),
            onAddFolder: {}
        ).background(Color.white).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }

        for width: CGFloat in [1000, 840, 632, 472, 867, 868, 1000] {
            window.setContentSize(CGSize(width: width, height: 640))
            controller.view.layoutSubtreeIfNeeded()
            var markerPixels = 0
            for _ in 0..<100 {
                markerPixels = try renderedPromptRailPixelCount(in: controller.view)
                if markerPixels > 4 { break }
                try await Task.sleep(nanoseconds: 20_000_000)
                controller.view.layoutSubtreeIfNeeded()
            }
            XCTAssertGreaterThan(markerPixels, 4, "Rendered prompt navigation disappeared at transcript width \(width)")
            XCTAssertLessThanOrEqual(controller.view.frame.width, width + 1)
        }
        await store.stop()
    }

    // Render the REAL conversation, not the standalone rail preview. Restrict
    // detection to the reserved gutter so a blue control elsewhere cannot pass.
    private func renderedPromptRailPixelCount(in view: NSView) throws -> Int {
        let size = view.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let firstX = max(0, Int(size.width - PromptRailLayout.edgeInset - PromptRailLayout.railWidth))
        var count = 0
        for x in firstX..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.9,
                      (0.35...0.65).contains(color.redComponent),
                      color.greenComponent > color.redComponent + 0.05,
                      color.blueComponent > color.greenComponent + 0.06 else { continue }
                count += 1
            }
        }
        return count
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

    func testFirstPromptUpdatesSidebarAndPersistsTitleBeforeResponse() async throws {
        for profile in [AgentHostSessionProfile.chat, .work] {
            let host = FakeAgentHost()
            await host.holdPromptResponses(true)
            let store = SessionStore(service: host)
            _ = try await store.createDraft(
                cwd: "/tmp/project",
                sessionDirectory: nil,
                profile: profile
            )

            let prompt = Task {
                try await store.submitPrompt(sessionId: "session-one", text: "  Fix\n the build  ")
            }
            try await waitUntil { await host.hasPendingPrompt }

            XCTAssertEqual(store.records["session-one"]?.descriptor.title, "Fix the build")
            XCTAssertEqual(store.records["session-one"]?.runState, .submitting)
            let sidebarTitle = profile == .chat
                ? store.chatSessions.first?.title
                : store.workSessionsByProjectPath["/tmp/project"]?.first?.title
            XCTAssertEqual(sidebarTitle, "Fix the build")
            try await waitUntil { await host.renamedTitles == ["Fix the build"] }
            XCTAssertEqual(store.records["session-one"]?.runState, .submitting)

            await host.completePrompt()
            _ = try await prompt.value
            await store.stop()
        }
    }

    func testSlowTitleSaveDoesNotBlockPromptCompletion() async throws {
        let host = FakeAgentHost()
        await host.holdRenameResponses(true)
        let store = SessionStore(service: host)
        _ = try await store.createDraft(cwd: "/tmp/project", sessionDirectory: nil, profile: .chat)
        var completed = false
        let prompt = Task {
            _ = try await store.submitPrompt(sessionId: "session-one", text: "Fix the build")
            completed = true
        }

        try await waitUntil { await host.hasPendingRename }
        try await waitUntil { completed }
        XCTAssertTrue(completed)
        XCTAssertEqual(store.records["session-one"]?.runState, .idle)
        XCTAssertEqual(store.chatSessions.first?.title, "Fix the build")

        await host.completeRename()
        try await prompt.value
        await store.stop()
    }

    func testRenameFailureKeepsLocalTitleAndDoesNotFailPrompt() async throws {
        let host = FakeAgentHost()
        await host.rejectRenames(true)
        let store = SessionStore(service: host)
        _ = try await store.createDraft(cwd: "/tmp/project", sessionDirectory: nil, profile: .chat)

        _ = try await store.submitPrompt(sessionId: "session-one", text: "Fix the build")
        try await waitUntil { await host.renamedTitles == ["Fix the build"] }

        XCTAssertEqual(store.records["session-one"]?.runState, .idle)
        XCTAssertEqual(store.records["session-one"]?.descriptor.title, "Fix the build")
        XCTAssertEqual(store.chatSessions.first?.title, "Fix the build")
        _ = try await store.submitPrompt(sessionId: "session-one", text: "Continue")
        XCTAssertEqual(store.chatSessions.first?.title, "Fix the build")
        await store.stop()
    }

    func testPromptDoesNotOverwriteAnExistingTitle() async throws {
        let host = FakeAgentHost()
        let store = SessionStore(service: host)
        _ = try await store.createDraft(cwd: "/tmp/project", sessionDirectory: nil, profile: .chat)
        await host.emit(.sessionInfoChanged(.init(
            sessionId: "session-one", sequence: 1, title: "My custom title", updatedAt: nil
        )))
        try await waitUntil { store.chatSessions.first?.title == "My custom title" }

        _ = try await store.submitPrompt(sessionId: "session-one", text: "Fix the build")

        XCTAssertEqual(store.records["session-one"]?.descriptor.title, "My custom title")
        XCTAssertEqual(store.chatSessions.first?.title, "My custom title")
        let renamedTitles = await host.renamedTitles
        XCTAssertTrue(renamedTitles.isEmpty)
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

    func testMouseWheelAtTopRevealsCachedHistoryInActualChatView() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(messages: (1...140).map {
            makeSessionMessage(id: "cached-\($0)", text: "Cached question \($0)")
        }))
        let fixture = try await historyConversation(host: host)
        defer { fixture.window.close() }
        let oldIDs = Set(fixture.observer.viewport?.frames.keys.map { $0 } ?? [])
        scrollHistoryToTop(fixture)
        try await waitForHistoryWindow(fixture, previousIDs: oldIDs)
        XCTAssertGreaterThan(fixture.scroll.contentView.bounds.minY, 160, "Keep the previously visible row anchored after prepending")
        XCTAssertLessThan(fixture.scroll.contentView.bounds.maxY, fixture.scroll.documentView?.bounds.maxY ?? 0,
                          "Reading history must not jump back to the latest message")
        let requests = await host.transcriptPageCount
        XCTAssertEqual(requests, 0, "Cached history should not require a host round trip")
        await fixture.store.stop()
    }

    func testMouseWheelLoadsTwoRemoteHistoryPagesWithoutLeavingConversation() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(messages: (81...120).map {
            makeSessionMessage(id: "remote-\($0)", text: "Remote question \($0)")
        }, history: AgentHostSessionHistory(revision: "history-revision", nextCursor: "page-one", hasMore: true)))
        await host.setTranscriptPage(AgentHostSessionTranscriptPageResult(
            sessionId: "session-one", messages: (41...80).map {
                makeSessionMessage(id: "remote-\($0)", text: "Remote question \($0)")
            }, revision: "history-revision", nextCursor: "page-two", hasMore: true
        ))
        let fixture = try await historyConversation(host: host)
        defer { fixture.window.close() }
        var oldIDs = Set(fixture.observer.viewport?.frames.keys.map { $0 } ?? [])
        scrollHistoryToTop(fixture)
        try await waitForHistoryWindow(fixture, previousIDs: oldIDs)
        var requests = await host.transcriptPageCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(fixture.store.records["session-one"]?.messages.count, 80)

        await host.setTranscriptPage(AgentHostSessionTranscriptPageResult(
            sessionId: "session-one", messages: (1...40).map {
                makeSessionMessage(id: "remote-\($0)", text: "Remote question \($0)")
            }, revision: "history-revision", nextCursor: nil, hasMore: false
        ))
        oldIDs = Set(fixture.observer.viewport?.frames.keys.map { $0 } ?? [])
        scrollHistoryToTop(fixture)
        try await waitForHistoryWindow(fixture, previousIDs: oldIDs)
        requests = await host.transcriptPageCount
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(fixture.store.records["session-one"]?.messages.count, 120)
        XCTAssertEqual(fixture.store.records["session-one"]?.messages.first?.id, "remote-1")
        XCTAssertEqual(fixture.store.records["session-one"]?.hasEarlierMessages, false)
        XCTAssertGreaterThan(fixture.scroll.contentView.bounds.minY, 160)
        await fixture.store.stop()
    }

    func testFailedHistoryLoadCanRetryWithAnotherWheelNotchAtTheSameTopPosition() async throws {
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(messages: (41...80).map {
            makeSessionMessage(id: "retry-\($0)", text: "Retry question \($0)")
        }, history: AgentHostSessionHistory(revision: "retry-revision", nextCursor: "retry-cursor", hasMore: true)))
        await host.setTranscriptPage(AgentHostSessionTranscriptPageResult(
            sessionId: "session-one", messages: (1...40).map {
                makeSessionMessage(id: "retry-\($0)", text: "Retry question \($0)")
            }, revision: "retry-revision", nextCursor: nil, hasMore: false
        ))
        await host.rejectTranscriptPages(true)
        let fixture = try await historyConversation(host: host)
        defer { fixture.window.close() }
        scrollHistoryToTop(fixture)
        for _ in 0..<100 {
            if await host.transcriptPageCount > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        var requests = await host.transcriptPageCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(fixture.store.records["session-one"]?.messages.count, 40)
        await host.rejectTranscriptPages(false)
        let oldIDs = Set(fixture.observer.viewport?.frames.keys.map { $0 } ?? [])
        scrollHistoryToTop(fixture)
        try await waitForHistoryWindow(fixture, previousIDs: oldIDs)
        requests = await host.transcriptPageCount
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(fixture.store.records["session-one"]?.messages.count, 80)
        await fixture.store.stop()
    }

    func testHistoryRestoresAnchorWhenAdjacentToolRowsMerge() async throws {
        let host = FakeAgentHost()
        var messages = (0..<110).map { makeSessionMessage(id: "history-\($0)", text: "History message \($0)") }
        func assistant(_ id: String, _ content: [AgentHostSessionMessageContent]) -> AgentHostSessionMessage {
            AgentHostSessionMessage(id: id, role: .assistant, content: content,
                timestamp: "2026-08-09T00:00:00.000Z", provider: nil, model: nil,
                stopReason: nil, errorMessage: nil, toolCallId: nil, toolName: nil, isError: nil)
        }
        messages[9] = assistant("preceding", [.text("Preparing"), .toolCall(id: "tool-one", name: "bash", argumentsSummary: "{}")])
        messages[10] = assistant("old-anchor", [.toolCall(id: "tool-two", name: "bash", argumentsSummary: "{}")])
        await host.setSnapshot(makeStoreSnapshot(messages: messages))
        let fixture = try await historyConversation(host: host)
        defer { fixture.window.close() }
        let viewport = try XCTUnwrap(fixture.observer.viewport)
        XCTAssertNotNil(viewport.frames["old-anchor"])
        scrollHistoryToTop(fixture)
        let expectedOffset = try XCTUnwrap(viewport.currentFrame(for: "old-anchor")).minY
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            if viewport.frames["old-anchor"] == nil,
               let restored = viewport.currentFrame(for: "preceding"),
               abs(restored.minY - expectedOffset) <= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(viewport.frames["old-anchor"], "The original tool-only row was merged")
        let restored = try XCTUnwrap(viewport.currentFrame(for: "preceding"))
        XCTAssertEqual(restored.minY, expectedOffset, accuracy: 2,
                       "Restore the original offset in the merged row; tool=\(String(describing: viewport.currentFrame(for: "tool:tool-two"))), scroll=\(fixture.scroll.contentView.bounds.minY)")
        await fixture.store.stop()
    }

    func testStreamingNewMessageDoesNotMoveReaderOutOfHistory() async throws {
        let host = FakeAgentHost()
        let messages = (0..<180).map { makeSessionMessage(id: "history-\($0)", text: "History message \($0)") }
        await host.setSnapshot(makeStoreSnapshot(messages: messages))
        let fixture = try await historyConversation(host: host)
        defer { fixture.window.close() }
        let viewport = try XCTUnwrap(fixture.observer.viewport)
        scrollHistoryToTop(fixture)
        let expectedOffset = try XCTUnwrap(viewport.currentFrame(for: "history-80")).minY
        for _ in 0..<150 {
            if viewport.frames["history-0"] != nil,
               let frame = viewport.currentFrame(for: "history-80"), abs(frame.minY - expectedOffset) < 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let restored = try XCTUnwrap(viewport.frames["history-80"])
        XCTAssertEqual(restored.minY, expectedOffset, accuracy: 2, "Wait for the exact history offset before streaming")
        let visible = viewport.frames.filter { $0.value.maxY > 0 && $0.value.minY < fixture.scroll.contentView.bounds.height }
        let anchor = try XCTUnwrap(visible.min { $0.value.minY < $1.value.minY })
        await host.emit(.sessionAssistantContent(AgentHostSessionAssistantContentPayload(
            sessionId: "session-one", sequence: 1, turnId: "new-turn", generationIndex: 0,
            phase: .delta, contentType: .text, contentIndex: 0, delta: "New streaming response",
            content: nil, toolCall: nil
        )))
        for _ in 0..<100 {
            if (fixture.store.records["session-one"]?.transcript.count ?? 0) > 180 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(fixture.store.records["session-one"]?.transcript.count ?? 0, 180)
        let after = try XCTUnwrap(viewport.frames[anchor.key])
        XCTAssertEqual(after.minY, anchor.value.minY, accuracy: 2, "Streaming must not shift the reading position")
        XCTAssertFalse(viewport.frames.keys.contains { $0.contains("new-turn") })
        await fixture.store.stop()
    }

    func testStreamingWhileReadingWithinRecentWindowKeepsTheVisibleAnchor() async throws {
        let host = FakeAgentHost()
        let messages = (0..<80).map { makeSessionMessage(id: "history-\($0)", text: "History message \($0)") }
        await host.setSnapshot(makeStoreSnapshot(messages: messages))
        let fixture = try await historyConversation(host: host)
        defer { fixture.window.close() }
        let viewport = try XCTUnwrap(fixture.observer.viewport)
        let point = fixture.scroll.convert(CGPoint(x: 100, y: 100), to: nil)
        fixture.observer.handleScrollWheel(TestPhaseLessScrollWheelEvent(window: fixture.window, point: point))
        var bounds = fixture.scroll.contentView.bounds
        bounds.origin.y = max(200, bounds.origin.y - 300)
        fixture.scroll.contentView.scroll(to: fixture.scroll.contentView.constrainBoundsRect(bounds).origin)
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: fixture.scroll.contentView)
        try await Task.sleep(nanoseconds: 160_000_000)
        let visible = viewport.frames.filter { $0.value.maxY > 0 && $0.value.minY < fixture.scroll.contentView.bounds.height }
        let anchor = try XCTUnwrap(visible.min { $0.value.minY < $1.value.minY })
        await host.emit(.sessionAssistantContent(AgentHostSessionAssistantContentPayload(
            sessionId: "session-one", sequence: 1, turnId: "new-turn", generationIndex: 0,
            phase: .delta, contentType: .text, contentIndex: 0, delta: "New streaming response",
            content: nil, toolCall: nil
        )))
        for _ in 0..<100 {
            if (fixture.store.records["session-one"]?.transcript.count ?? 0) > 80 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(fixture.store.records["session-one"]?.transcript.count ?? 0, 80)
        let after = try XCTUnwrap(viewport.frames[anchor.key])
        XCTAssertEqual(after.minY, anchor.value.minY, accuracy: 2)
        XCTAssertFalse(viewport.frames.keys.contains { $0.contains("new-turn") })
        await fixture.store.stop()
    }

    func testLongHistoryCanScrollBackToLatestWithoutSkippingRows() async throws {
        let host = FakeAgentHost()
        let messages = (0..<500).map { index -> AgentHostSessionMessage in
            let paragraph = String(repeating: "History content \(index) is presented as Markdown. ", count: 1 + index % 5)
            let parts: [AgentHostSessionMessageContent] = [.text("## Message \(index)\n\n" + paragraph)]
            return AgentHostSessionMessage(
                id: "row-\(index)", role: index % 7 == 0 ? .user : .assistant,
                content: parts, timestamp: "2026-08-09T00:00:00.000Z", provider: nil,
                model: nil, stopReason: nil, errorMessage: nil, toolCallId: nil, toolName: nil, isError: nil
            )
        }
        await host.setSnapshot(makeStoreSnapshot(messages: messages))
        let fixture = try await historyConversation(host: host)
        defer { fixture.window.close() }
        let viewport = try XCTUnwrap(fixture.observer.viewport)
        for _ in 0..<4 {
            let previousFirst = viewport.frames.keys.compactMap { Int($0.replacingOccurrences(of: "row-", with: "")) }.min() ?? 500
            scrollHistoryToTop(fixture)
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 20_000_000)
                let first = viewport.frames.keys.compactMap { Int($0.replacingOccurrences(of: "row-", with: "")) }.min() ?? 500
                if first < previousFirst { break }
            }
            try await Task.sleep(nanoseconds: 90_000_000)
            let first = viewport.frames.keys.compactMap { Int($0.replacingOccurrences(of: "row-", with: "")) }.min() ?? 500
            XCTAssertLessThan(first, previousFirst, "Scrolling up must reveal an earlier bounded window")
            XCTAssertLessThanOrEqual(viewport.frames.count, TranscriptWindowNavigation.maximumCount)
        }
        var seen: Set<Int> = []
        var lastMaximum = -1
        var previousVisible: Set<Int> = []
        var latestVisibleSteps = 0
        let point = fixture.scroll.convert(CGPoint(x: 100, y: 100), to: nil)
        for _ in 0..<500 {
            fixture.observer.handleScrollWheel(DownHistoryWheel(window: fixture.window, point: point))
            var proposed = fixture.scroll.contentView.bounds
            proposed.origin.y += 200
            fixture.scroll.contentView.scroll(to: fixture.scroll.contentView.constrainBoundsRect(proposed).origin)
            fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: fixture.scroll.contentView)
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
            let visible = viewport.frames.filter { $0.value.maxY > 0 && $0.value.minY < fixture.scroll.contentView.bounds.height }
            let indices = Set(visible.keys.compactMap { Int($0.replacingOccurrences(of: "row-", with: "")) })
            XCTAssertLessThanOrEqual(viewport.frames.count, TranscriptWindowNavigation.maximumCount)
            if let maximum = indices.max() {
                XCTAssertGreaterThanOrEqual(maximum, lastMaximum, "Scrolling down must not return to earlier rows")
                if let oldMax = previousVisible.max(), let newMin = indices.min(), newMin > oldMax + 1 {
                    XCTFail("Scrolling must not skip messages (\(oldMax) to \(newMin))")
                }
                lastMaximum = maximum
                seen.formUnion(indices)
                previousVisible = indices
            }
            if let frame = viewport.frames["row-499"], frame.minY >= 0, frame.maxY <= fixture.scroll.contentView.bounds.height {
                latestVisibleSteps += 1
            } else { latestVisibleSteps = 0 }
            if latestVisibleSteps >= 3 { break }
        }
        XCTAssertGreaterThanOrEqual(latestVisibleSteps, 3, "The latest message must remain fully visible")
        if let first = seen.min() {
            let missing = Set(first...499).subtracting(seen)
            XCTAssertTrue(missing.isEmpty, "Every intervening row must be reachable; missing \(missing.sorted().prefix(10))")
        } else {
            XCTFail("No transcript rows were visible")
        }
        await fixture.store.stop()
    }

    private typealias HistoryFixture = (store: SessionStore, window: NSWindow, scroll: NSScrollView, observer: TranscriptUserScrollObserverView)

    private func historyConversation(host: FakeAgentHost) async throws -> HistoryFixture {
        let store = SessionStore(service: host)
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
        let controller = NSHostingController(rootView: ChatView(
            mode: .work, projects: [], selectedProject: .constant(PiProject(name: "Project", path: "/tmp/project")),
            sessionStore: store, composerDrafts: SessionComposerDraftStore(), onAddFolder: {}
        ).background(Color.white).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 840, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 840, height: 640))
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        var previousHeight: CGFloat = -1
        var stableFrames = 0
        for _ in 0..<100 {
            controller.view.layoutSubtreeIfNeeded()
            if let observer = historyDescendants(controller.view).compactMap({ $0 as? TranscriptUserScrollObserverView }).first,
               let scroll = observer.enclosingScrollView,
               let height = scroll.documentView?.bounds.height, height > 1000 {
                stableFrames = abs(height - previousHeight) < 1 ? stableFrames + 1 : 0
                previousHeight = height
                if stableFrames >= 3 { return (store, window, scroll, observer) }
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        window.close()
        throw NSError(domain: "HistoryRenderingTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The initial transcript did not finish rendering"])
    }

    private func historyDescendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { historyDescendants($0) }
    }

    private func scrollHistoryToTop(_ fixture: HistoryFixture) {
        let point = fixture.scroll.convert(CGPoint(x: 5, y: 5), to: nil)
        fixture.observer.handleScrollWheel(TestPhaseLessScrollWheelEvent(window: fixture.window, point: point))
        fixture.scroll.contentView.scroll(to: .zero)
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: fixture.scroll.contentView)
    }

    private func waitForHistoryWindow(_ fixture: HistoryFixture, previousIDs: Set<String>) async throws {
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            let ids = Set(fixture.observer.viewport?.frames.keys.map { $0 } ?? [])
            if !ids.isEmpty, ids != previousIDs {
                // Fixed windows change identities, not necessarily document height.
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
        }
        XCTFail("Scrolling to the top did not change the historical window")
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
        XCTAssertEqual(store.records["session-one"]?.descriptor.title, "Hello")
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
        try await waitUntil { await host.renamedTitles == ["Build the feature"] }
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

    func testStreamingBurstPublishesOnlyOnceAndFlushesOnCompletion() async throws {
        let host = FakeAgentHost()
        let store = SessionStore(service: host, streamingPublishDelayNanoseconds: 10_000_000_000)
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        await host.emit(.sessionStateChanged(.init(
            sessionId: "session-one", sequence: 1, turnId: "turn-one", state: .running
        )))
        try await waitUntil { store.records["session-one"]?.lastSequence == 1 }

        var publications: [SessionRecord] = []
        let subscription = store.recordsPublisher.dropFirst().sink {
            if let record = $0["session-one"] { publications.append(record) }
        }
        for sequence in 2...21 {
            await host.emit(.sessionMessageDelta(.init(
                sessionId: "session-one", sequence: sequence, turnId: "turn-one", delta: "x"
            )))
        }
        await host.emit(.sessionStateChanged(.init(
            sessionId: "session-one", sequence: 22, turnId: "turn-one", state: .idle
        )))
        try await waitUntil { store.records["session-one"]?.lastSequence == 22 }

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.last?.runState, .idle)
        XCTAssertEqual(publications.last?.messages.last?.content, [.text(String(repeating: "x", count: 20))])
        subscription.cancel()
        await store.stop()
    }

    func testStreamingWindowUpdatesOnlyTheAffectedConversationWithoutWorkspaceInvalidation() async throws {
        let host = FakeAgentHost()
        let store = SessionStore(service: host)
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        await host.emit(.sessionStateChanged(.init(
            sessionId: "session-one", sequence: 1, turnId: "turn-one", state: .running
        )))
        try await waitUntil { store.records["session-one"]?.lastSequence == 1 }

        var workspaceUpdates = 0
        var changedSessions: [Set<String>] = []
        let workspaceSubscription = store.objectWillChange.sink { workspaceUpdates += 1 }
        let recordSubscription = store.recordUpdates.sink { changedSessions.append($0) }
        await host.emit(.sessionMessageDelta(.init(
            sessionId: "session-one", sequence: 2, turnId: "turn-one", delta: "partial"
        )))
        try await waitUntil { store.records["session-one"]?.lastSequence == 2 }

        XCTAssertEqual(workspaceUpdates, 0)
        XCTAssertEqual(changedSessions, [["session-one"]])
        XCTAssertEqual(store.records["session-one"]?.messages.last?.content, [.text("partial")])
        await host.emit(.sessionStateChanged(.init(
            sessionId: "session-one", sequence: 3, turnId: "turn-one", state: .idle
        )))
        try await waitUntil { store.records["session-one"]?.lastSequence == 3 }
        XCTAssertEqual(workspaceUpdates, 1)
        workspaceSubscription.cancel()
        recordSubscription.cancel()
        await store.stop()
    }

    func testStreamingErrorFlushesTextImmediatelyAndCancelsDelayedPublication() async throws {
        let host = FakeAgentHost()
        let store = SessionStore(service: host, streamingPublishDelayNanoseconds: 10_000_000_000)
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        await host.emit(.sessionMessageDelta(.init(
            sessionId: "session-one", sequence: 1, turnId: "turn-one", delta: "preserved"
        )))
        await host.emit(.sessionError(.init(
            sessionId: "session-one", sequence: 2, turnId: "turn-one", code: "test", message: "failed"
        )))
        try await waitUntil { store.records["session-one"]?.runState == .failed }
        XCTAssertEqual(store.records["session-one"]?.messages.last?.content, [.text("preserved")])
        await store.stop()
    }

    func testApprovalFlushesCoalescedThinkingAndToolOutputWithoutDelay() async throws {
        let host = FakeAgentHost()
        let store = SessionStore(service: host, streamingPublishDelayNanoseconds: 10_000_000_000)
        try await store.openSession(makeSummary(), profile: .chat, sessionDirectory: nil)
        await host.emit(.sessionAssistantContent(.init(
            sessionId: "session-one", sequence: 1, turnId: "turn-one",
            generationIndex: 0, phase: .delta, contentType: .thinking, contentIndex: 0,
            delta: "thinking", content: nil, toolCall: nil
        )))
        await host.emit(.sessionToolUpdated(.init(
            sessionId: "session-one", sequence: 2, turnId: "turn-one",
            toolCallId: "tool-one", toolName: "write", output: "partial output"
        )))
        await host.emit(.sessionApprovalRequested(.init(
            sessionId: "session-one", sequence: 3, turnId: "turn-one",
            requestId: "approval-one", toolCallId: "tool-one", toolName: "write", summary: "Write file"
        )))
        try await waitUntil { store.records["session-one"]?.pendingApprovals.count == 1 }
        XCTAssertEqual(store.records["session-one"]?.lastSequence, 3)
        XCTAssertEqual(store.records["session-one"]?.tools.last?.output, "partial output")
        XCTAssertEqual(store.records["session-one"]?.tools.last?.state, .awaitingApproval)
        let thinkingTexts = store.records["session-one"]?.transcript.flatMap(\.parts).compactMap { part -> String? in
            guard case .thinking(let thinking) = part else { return nil }
            return thinking.text
        }
        XCTAssertEqual(thinkingTexts, ["thinking"])
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

// Shared fixture for Store and real transcript integration acceptance tests.
actor FakeAgentHost: AgentHostServicing {
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
    private var transcriptPagesByCursor: [String: AgentHostSessionTranscriptPageResult] = [:]
    private var transcriptPageDelayNanoseconds: UInt64 = 0
    private var gitBranchesResult = AgentHostGitBranchesResult.unavailable
    private var shouldEmitRunningBeforeResponse = false
    private var shouldRejectPrompts = false
    private var shouldHoldPromptResponses = false
    private var pendingPrompt: CheckedContinuation<Void, Never>?
    private var shouldRejectRenames = false
    private var shouldHoldRenameResponses = false
    private var pendingRename: CheckedContinuation<Void, Never>?
    private var shouldRejectSnapshots = false
    private var shouldRejectTranscriptPages = false
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
        transcriptPagesByCursor = [:]
    }

    func setTranscriptPagesByCursor(_ pages: [String: AgentHostSessionTranscriptPageResult]) {
        transcriptPagesByCursor = pages
    }

    func setTranscriptPageDelay(nanoseconds: UInt64) { transcriptPageDelayNanoseconds = nanoseconds }

    func rejectTranscriptPages(_ enabled: Bool) {
        shouldRejectTranscriptPages = enabled
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

    func holdPromptResponses(_ enabled: Bool) {
        shouldHoldPromptResponses = enabled
    }

    var hasPendingPrompt: Bool { pendingPrompt != nil }

    func completePrompt() {
        pendingPrompt?.resume()
        pendingPrompt = nil
    }

    func rejectRenames(_ enabled: Bool) {
        shouldRejectRenames = enabled
    }

    func holdRenameResponses(_ enabled: Bool) {
        shouldHoldRenameResponses = enabled
    }

    var hasPendingRename: Bool { pendingRename != nil }

    func completeRename() {
        pendingRename?.resume()
        pendingRename = nil
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
        if transcriptPageDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: transcriptPageDelayNanoseconds) }
        if shouldRejectTranscriptPages {
            throw AgentHostClientError.requestFailed(code: "history_fixture_failure", message: "History transport fixture unavailable")
        }
        return transcriptPagesByCursor[cursor] ?? transcriptPageResult
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
        if shouldRejectRenames {
            throw FakeAgentHostError.renameRejected
        }
        if shouldHoldRenameResponses {
            await withCheckedContinuation { pendingRename = $0 }
        }
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
        if shouldHoldPromptResponses {
            await withCheckedContinuation { pendingPrompt = $0 }
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
    case renameRejected
}

struct HTMLExportRequest: Equatable {
    let sessionId: String
    let path: String
    let sessionDirectory: String?
    let profile: AgentHostSessionProfile
    let outputPath: String
}

struct ApprovalResolution: Equatable {
    let requestId: String
    let decision: AgentHostApprovalDecision
}

struct ElicitationResolution: Equatable {
    let requestId: String
    let response: AgentHostACPElicitationResponse
}

struct ModelOptionSelection: Equatable {
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
