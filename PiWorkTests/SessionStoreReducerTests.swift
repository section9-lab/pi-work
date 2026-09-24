import XCTest
@testable import PiWork

final class SessionStoreReducerTests: XCTestCase {
    func testSnapshotCanBeProjectedAwayFromTheMainActor() async {
        let snapshot = makeSnapshot(sessionId: "session-one")

        let record = await Task.detached {
            SessionStoreReducer.project(
                snapshot: snapshot,
                profile: .work,
                sessionDirectory: nil
            )
        }.value

        XCTAssertEqual(record.id, "session-one")
        XCTAssertEqual(record.profile, .work)
    }

    func testSubmittingImagePromptImmediatelyIncludesImageMetadata() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .chat,
            sessionDirectory: nil
        )
        let image = AgentHostPromptImage(
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )

        _ = reducer.submitPrompt(
            sessionId: "session-one",
            turnId: "turn-one",
            text: "",
            images: [image],
            timestamp: "2026-08-09T00:00:01.000Z"
        )

        let record = try XCTUnwrap(reducer.records["session-one"])
        XCTAssertEqual(
            record.messages.last?.content,
            [.image(mimeType: "image/png", data: image.data)]
        )
        XCTAssertEqual(
            record.transcript.last?.parts,
            [
                .image(
                    id: "turn:turn-one:user:image:0",
                    mimeType: "image/png",
                    data: image.data
                )
            ]
        )
    }

    func testSubmittingSkillPromptImmediatelyKeepsSkillAndCleanUserText() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        _ = reducer.submitPrompt(
            sessionId: "session-one",
            turnId: "turn-one",
            text: "/skill:ego-browser 使用这个再试试呢",
            timestamp: "2026-08-09T00:00:01.000Z"
        )

        let record = try XCTUnwrap(reducer.records["session-one"])
        XCTAssertEqual(
            record.messages.last?.content,
            [
                .skill(name: "ego-browser"),
                .text("使用这个再试试呢")
            ]
        )
        let transcriptMessage = try XCTUnwrap(record.transcript.last)
        XCTAssertEqual(transcriptMessage.parts.count, 2)
        XCTAssertEqual(PiChatMessage(message: transcriptMessage).text, "使用这个再试试呢")
    }

    func testRunningEventBeforePromptResponseDoesNotRegressToSubmitting() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .chat,
            sessionDirectory: "/tmp/sessions"
        )

        let effects = reducer.submitPrompt(
            sessionId: "session-one",
            turnId: "turn-one",
            text: "  Build\n the   feature  ",
            timestamp: "2026-08-09T00:00:01.000Z"
        )
        XCTAssertEqual(
            effects,
            [.renameSession(sessionId: "session-one", title: "Build the feature")]
        )
        XCTAssertEqual(reducer.records["session-one"]?.runState, .submitting)

        _ = reducer.receive(
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    state: .running
                )
            ),
            timestamp: "2026-08-09T00:00:02.000Z"
        )
        reducer.promptAccepted(sessionId: "session-one", turnId: "turn-one")

        XCTAssertEqual(reducer.records["session-one"]?.runState, .running)
        XCTAssertEqual(reducer.records["session-one"]?.activeTurnId, "turn-one")
        XCTAssertEqual(reducer.records["session-one"]?.descriptor.title, "Build the feature")
        XCTAssertEqual(
            reducer.records["session-one"]?.messages.last?.content,
            [.text("  Build\n the   feature  ")]
        )
    }

    func testACPPromptCompletionReturnsTheLocalSessionToIdle() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .chat,
            sessionDirectory: nil
        )
        _ = reducer.submitPrompt(
            sessionId: "session-one",
            turnId: "turn-one",
            text: "Build the feature",
            timestamp: "2026-08-09T00:00:01.000Z"
        )

        reducer.promptCompleted(sessionId: "session-one", turnId: "turn-one")

        XCTAssertEqual(reducer.records["session-one"]?.runState, .idle)
        XCTAssertNil(reducer.records["session-one"]?.activeTurnId)
    }

    func testMessageDeltaIgnoresDuplicatesAndRequestsSnapshotForSequenceGap() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .chat,
            sessionDirectory: nil
        )

        let firstEffects = reducer.receive(
            .sessionMessageDelta(
                AgentHostSessionMessageDeltaPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    delta: "Hello"
                )
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )
        let duplicateEffects = reducer.receive(
            .sessionMessageDelta(
                AgentHostSessionMessageDeltaPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    delta: "Hello"
                )
            ),
            timestamp: "2026-08-09T00:00:02.000Z"
        )
        let gapEffects = reducer.receive(
            .sessionMessageDelta(
                AgentHostSessionMessageDeltaPayload(
                    sessionId: "session-one",
                    sequence: 3,
                    turnId: "turn-one",
                    delta: " skipped"
                )
            ),
            timestamp: "2026-08-09T00:00:03.000Z"
        )

        XCTAssertEqual(firstEffects, [])
        XCTAssertEqual(duplicateEffects, [])
        XCTAssertEqual(gapEffects, [.requestSnapshot(sessionId: "session-one")])
        XCTAssertEqual(reducer.records["session-one"]?.lastSequence, 1)
        XCTAssertEqual(
            reducer.records["session-one"]?.messages.last?.content,
            [.text("Hello")]
        )
    }

    func testEventsAreRoutedOnlyToTheirCorrelatedSession() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .chat,
            sessionDirectory: nil
        )
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-two"),
            profile: .chat,
            sessionDirectory: nil
        )

        _ = reducer.receive(
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-two",
                    sequence: 1,
                    turnId: "turn-two",
                    state: .running
                )
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )

        XCTAssertEqual(reducer.records["session-one"]?.runState, .idle)
        XCTAssertEqual(reducer.records["session-one"]?.lastSequence, 0)
        XCTAssertEqual(reducer.records["session-two"]?.runState, .running)
        XCTAssertEqual(reducer.records["session-two"]?.lastSequence, 1)
    }

    func testToolAndErrorEventsUpdateTheSessionRecord() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        _ = reducer.receive(
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    summary: #"{"path":"README.md"}"#
                )
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )
        _ = reducer.receive(
            .sessionToolCompleted(
                AgentHostSessionToolCompletedPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    isError: false
                )
            ),
            timestamp: "2026-08-09T00:00:02.000Z"
        )
        _ = reducer.receive(
            .sessionError(
                AgentHostSessionErrorPayload(
                    sessionId: "session-one",
                    sequence: 3,
                    turnId: "turn-one",
                    code: "agent_error",
                    message: "Model request failed"
                )
            ),
            timestamp: "2026-08-09T00:00:03.000Z"
        )

        XCTAssertEqual(
            reducer.records["session-one"]?.tools,
            [
                SessionToolRecord(
                    id: "tool-one",
                    name: "read",
                    summary: #"{"path":"README.md"}"#,
                    state: .completed,
                    isError: false
                )
            ]
        )
        XCTAssertEqual(reducer.records["session-one"]?.runState, .failed)
        XCTAssertEqual(reducer.records["session-one"]?.errorMessage, "Model request failed")
        XCTAssertNil(reducer.records["session-one"]?.activeTurnId)
    }

    func testStructuredACPToolContentReplacesAndPersistsAcrossStatusUpdates() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        _ = reducer.receive(
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "edit",
                    summary: "App.swift",
                    content: [.diff(path: "/tmp/App.swift", oldText: "old", newText: "new")]
                )
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )
        let imageContent: [AgentHostACPToolCallContent] = [
            .content(.image(mimeType: "image/png", data: Data([0x89]), uri: nil))
        ]
        _ = reducer.receive(
            .sessionToolUpdated(
                AgentHostSessionToolUpdatedPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "edit",
                    output: "",
                    content: imageContent
                )
            ),
            timestamp: "2026-08-09T00:00:02.000Z"
        )
        _ = reducer.receive(
            .sessionToolCompleted(
                AgentHostSessionToolCompletedPayload(
                    sessionId: "session-one",
                    sequence: 3,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "edit",
                    isError: false
                )
            ),
            timestamp: "2026-08-09T00:00:03.000Z"
        )

        let tool = try XCTUnwrap(reducer.records["session-one"]?.tools.first)
        XCTAssertEqual(tool.content, imageContent)
        XCTAssertEqual(tool.state, .completed)
    }

    func testTranscriptPreservesTextToolProgressAndFollowingTextOrder() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        _ = reducer.receive(
            .sessionMessageDelta(
                AgentHostSessionMessageDeltaPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    delta: "Before"
                )
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )
        _ = reducer.receive(
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    summary: #"{"path":"README.md"}"#
                )
            ),
            timestamp: "2026-08-09T00:00:02.000Z"
        )
        _ = reducer.receive(
            .sessionToolUpdated(
                AgentHostSessionToolUpdatedPayload(
                    sessionId: "session-one",
                    sequence: 3,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    output: "First line"
                )
            ),
            timestamp: "2026-08-09T00:00:03.000Z"
        )
        _ = reducer.receive(
            .sessionToolCompleted(
                AgentHostSessionToolCompletedPayload(
                    sessionId: "session-one",
                    sequence: 4,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    output: "README contents",
                    isError: false
                )
            ),
            timestamp: "2026-08-09T00:00:04.000Z"
        )
        _ = reducer.receive(
            .sessionMessageDelta(
                AgentHostSessionMessageDeltaPayload(
                    sessionId: "session-one",
                    sequence: 5,
                    turnId: "turn-one",
                    delta: "After"
                )
            ),
            timestamp: "2026-08-09T00:00:05.000Z"
        )

        let parts = try XCTUnwrap(reducer.records["session-one"]?.transcript.last?.parts)
        XCTAssertEqual(parts.count, 3)
        guard case .text(_, let before) = parts[0],
              case .tool(let tool) = parts[1],
              case .text(_, let after) = parts[2] else {
            return XCTFail("Expected text, tool, text transcript parts")
        }
        XCTAssertEqual(before, "Before")
        XCTAssertEqual(tool.output, "README contents")
        XCTAssertEqual(tool.state, .completed)
        XCTAssertEqual(tool.isError, false)
        XCTAssertEqual(after, "After")
    }

    func testAssistantContentPreservesThinkingTextToolAndNextGenerationOrder() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        let firstThinking = assistantContent(
            sequence: 1,
            generationIndex: 0,
            phase: .start,
            contentType: .thinking,
            contentIndex: 0
        )
        let firstTextStart = assistantContent(
            sequence: 2,
            generationIndex: 0,
            phase: .start,
            contentType: .text,
            contentIndex: 1
        )
        let firstText = assistantContent(
            sequence: 3,
            generationIndex: 0,
            phase: .delta,
            contentType: .text,
            contentIndex: 1,
            delta: "Checking"
        )
        let toolCall = AgentHostAssistantToolCall(
            id: "tool-one",
            name: "read",
            argumentsSummary: #"{"path":"README.md"}"#
        )
        let toolStart = assistantContent(
            sequence: 4,
            generationIndex: 0,
            phase: .start,
            contentType: .toolCall,
            contentIndex: 2,
            toolCall: toolCall
        )
        let toolEnd = assistantContent(
            sequence: 5,
            generationIndex: 0,
            phase: .end,
            contentType: .toolCall,
            contentIndex: 2,
            toolCall: toolCall
        )
        let firstThinkingEnd = assistantContent(
            sequence: 6,
            generationIndex: 0,
            phase: .end,
            contentType: .thinking,
            contentIndex: 0
        )

        for event in [firstThinking, firstTextStart, firstText, toolStart, toolEnd, firstThinkingEnd] {
            _ = reducer.receive(event, timestamp: "2026-08-09T00:00:01.000Z")
        }
        _ = reducer.receive(
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 7,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    summary: #"{"path":"README.md"}"#
                )
            ),
            timestamp: "2026-08-09T00:00:02.000Z"
        )
        _ = reducer.receive(
            .sessionToolCompleted(
                AgentHostSessionToolCompletedPayload(
                    sessionId: "session-one",
                    sequence: 8,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    output: "README contents",
                    isError: false
                )
            ),
            timestamp: "2026-08-09T00:00:03.000Z"
        )
        for event in [
            assistantContent(
                sequence: 9,
                generationIndex: 1,
                phase: .start,
                contentType: .thinking,
                contentIndex: 0
            ),
            assistantContent(
                sequence: 10,
                generationIndex: 1,
                phase: .end,
                contentType: .thinking,
                contentIndex: 0
            ),
            assistantContent(
                sequence: 11,
                generationIndex: 1,
                phase: .start,
                contentType: .text,
                contentIndex: 1
            ),
            assistantContent(
                sequence: 12,
                generationIndex: 1,
                phase: .delta,
                contentType: .text,
                contentIndex: 1,
                delta: "Done"
            )
        ] {
            _ = reducer.receive(event, timestamp: "2026-08-09T00:00:04.000Z")
        }

        let transcript = try XCTUnwrap(reducer.records["session-one"]?.transcript)
        XCTAssertEqual(transcript.count, 2)
        let firstParts = transcript[0].parts
        let secondParts = transcript[1].parts
        XCTAssertEqual(firstParts.count, 3)
        XCTAssertEqual(secondParts.count, 2)
        guard case .thinking(let firstThought) = firstParts[0],
              case .text(_, let before) = firstParts[1],
              case .tool(let tool) = firstParts[2],
              case .thinking(let secondThought) = secondParts[0],
              case .text(_, let after) = secondParts[1] else {
            return XCTFail("Expected each assistant generation to remain a separate row")
        }
        XCTAssertEqual(firstThought.state, .completed)
        XCTAssertEqual(before, "Checking")
        XCTAssertEqual(tool.output, "README contents")
        XCTAssertEqual(secondThought.state, .completed)
        XCTAssertEqual(after, "Done")
    }

    func testAssistantThinkingStreamsDeltasAndUsesFinalContent() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        for event in [
            assistantContent(
                sequence: 1,
                generationIndex: 0,
                phase: .start,
                contentType: .thinking,
                contentIndex: 0
            ),
            assistantContent(
                sequence: 2,
                generationIndex: 0,
                phase: .delta,
                contentType: .thinking,
                contentIndex: 0,
                delta: "Inspecting "
            ),
            assistantContent(
                sequence: 3,
                generationIndex: 0,
                phase: .delta,
                contentType: .thinking,
                contentIndex: 0,
                delta: "sources"
            ),
            assistantContent(
                sequence: 4,
                generationIndex: 0,
                phase: .end,
                contentType: .thinking,
                contentIndex: 0,
                content: "Inspecting sources."
            )
        ] {
            _ = reducer.receive(event, timestamp: "2026-08-09T00:00:01.000Z")
        }

        let parts = try XCTUnwrap(reducer.records["session-one"]?.transcript.first?.parts)
        guard case .thinking(let thinking) = try XCTUnwrap(parts.first) else {
            return XCTFail("Expected a thinking transcript part")
        }
        XCTAssertEqual(thinking.state, .completed)
        XCTAssertEqual(thinking.text, "Inspecting sources.")
    }

    func testAssistantThinkingKeepsStreamedTextWhenFinalContentIsEmptyBeforeTool() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        for event in [
            assistantContent(
                sequence: 1,
                generationIndex: 0,
                phase: .start,
                contentType: .thinking,
                contentIndex: 0
            ),
            assistantContent(
                sequence: 2,
                generationIndex: 0,
                phase: .delta,
                contentType: .thinking,
                contentIndex: 0,
                delta: "Checking the browser state."
            ),
            assistantContent(
                sequence: 3,
                generationIndex: 0,
                phase: .end,
                contentType: .thinking,
                contentIndex: 0,
                content: ""
            ),
            assistantContent(
                sequence: 4,
                generationIndex: 0,
                phase: .end,
                contentType: .toolCall,
                contentIndex: 1,
                toolCall: AgentHostAssistantToolCall(
                    id: "tool-one",
                    name: "bash",
                    argumentsSummary: "pageInfo"
                )
            )
        ] {
            _ = reducer.receive(event, timestamp: "2026-08-09T00:00:01.000Z")
        }

        let parts = try XCTUnwrap(reducer.records["session-one"]?.transcript.first?.parts)
        XCTAssertEqual(parts.count, 2)
        guard case .thinking(let thinking) = parts[0],
              case .tool = parts[1] else {
            return XCTFail("Expected streamed thinking followed by the tool")
        }
        XCTAssertEqual(thinking.state, .completed)
        XCTAssertEqual(thinking.text, "Checking the browser state.")
    }

    func testIdleStateMarksAnUnfinishedToolAsCancelled() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )
        _ = reducer.receive(
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "bash",
                    summary: "sleep 10"
                )
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )

        _ = reducer.receive(
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    state: .idle
                )
            ),
            timestamp: "2026-08-09T00:00:02.000Z"
        )

        let tool = try XCTUnwrap(reducer.records["session-one"]?.tools.first)
        XCTAssertEqual(tool.state, .cancelled)
        XCTAssertNil(tool.approval)
    }

    func testSessionErrorFailsAnUnfinishedToolWithTheErrorMessage() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )
        _ = reducer.receive(
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "bash",
                    summary: "bun test"
                )
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )

        _ = reducer.receive(
            .sessionError(
                AgentHostSessionErrorPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    code: "agent_error",
                    message: "Model request failed"
                )
            ),
            timestamp: "2026-08-09T00:00:02.000Z"
        )

        let tool = try XCTUnwrap(reducer.records["session-one"]?.tools.first)
        XCTAssertEqual(tool.state, .completed)
        XCTAssertEqual(tool.isError, true)
        XCTAssertEqual(tool.output, "Model request failed")
        XCTAssertNil(tool.approval)
    }

    func testSnapshotProjectsToolResultIntoItsOriginalPosition() throws {
        let messages = [
            AgentHostSessionMessage(
                id: "assistant-before",
                role: .assistant,
                content: [
                    .text("Before"),
                    .toolCall(id: "tool-one", name: "read", argumentsSummary: #"{"path":"README.md"}"#)
                ],
                timestamp: "2026-08-09T00:00:01.000Z",
                provider: nil,
                model: nil,
                stopReason: nil,
                errorMessage: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil
            ),
            AgentHostSessionMessage(
                id: "tool-result",
                role: .tool,
                content: [.text("README contents")],
                timestamp: "2026-08-09T00:00:02.000Z",
                provider: nil,
                model: nil,
                stopReason: nil,
                errorMessage: nil,
                toolCallId: "tool-one",
                toolName: "read",
                isError: false
            ),
            AgentHostSessionMessage(
                id: "assistant-after",
                role: .assistant,
                content: [.text("After")],
                timestamp: "2026-08-09T00:00:03.000Z",
                provider: nil,
                model: nil,
                stopReason: nil,
                errorMessage: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil
            )
        ]
        var reducer = SessionStoreReducer()

        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one", messages: messages),
            profile: .work,
            sessionDirectory: nil
        )

        let transcript = try XCTUnwrap(reducer.records["session-one"]?.transcript)
        let parts = transcript.flatMap(\.parts)
        XCTAssertEqual(parts.count, 3)
        guard case .text(_, let before) = parts[0],
              case .tool(let tool) = parts[1],
              case .text(_, let after) = parts[2] else {
            return XCTFail("Expected snapshot to preserve text, tool, text order")
        }
        XCTAssertEqual(before, "Before")
        XCTAssertEqual(tool.output, "README contents")
        XCTAssertEqual(tool.state, .completed)
        XCTAssertEqual(after, "After")
    }

    func testSnapshotKeepsAssistantGenerationsAsSeparateTranscriptRows() throws {
        let messages = [
            AgentHostSessionMessage(
                id: "user-one",
                role: .user,
                content: [.text("Research this")],
                timestamp: "2026-08-09T00:00:00.000Z",
                provider: nil,
                model: nil,
                stopReason: nil,
                errorMessage: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil
            ),
            AgentHostSessionMessage(
                id: "assistant-one",
                role: .assistant,
                content: [
                    .thinking(text: "Inspecting", redacted: false),
                    .text("Checking"),
                    .toolCall(id: "tool-one", name: "read", argumentsSummary: "README.md")
                ],
                timestamp: "2026-08-09T00:00:01.000Z",
                provider: nil,
                model: nil,
                stopReason: "toolUse",
                errorMessage: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil
            ),
            AgentHostSessionMessage(
                id: "tool-result",
                role: .tool,
                content: [.text("README contents")],
                timestamp: "2026-08-09T00:00:02.000Z",
                provider: nil,
                model: nil,
                stopReason: nil,
                errorMessage: nil,
                toolCallId: "tool-one",
                toolName: "read",
                isError: false
            ),
            AgentHostSessionMessage(
                id: "assistant-two",
                role: .assistant,
                content: [.thinking(text: "Summarizing", redacted: false), .text("Done")],
                timestamp: "2026-08-09T00:00:03.000Z",
                provider: nil,
                model: nil,
                stopReason: "stop",
                errorMessage: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil
            )
        ]
        var reducer = SessionStoreReducer()

        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one", messages: messages),
            profile: .work,
            sessionDirectory: nil
        )

        let transcript = try XCTUnwrap(reducer.records["session-one"]?.transcript)
        XCTAssertEqual(transcript.map(\.role), [.user, .assistant, .assistant])
        let firstParts = transcript[1].parts
        let secondParts = transcript[2].parts
        XCTAssertEqual(firstParts.count, 3)
        XCTAssertEqual(secondParts.count, 2)
        guard case .thinking = firstParts[0],
              case .text(_, let before) = firstParts[1],
              case .tool(let tool) = firstParts[2],
              case .thinking = secondParts[0],
              case .text(_, let after) = secondParts[1] else {
            return XCTFail("Expected ordered assistant generation rows")
        }
        XCTAssertEqual(before, "Checking")
        XCTAssertEqual(tool.output, "README contents")
        XCTAssertEqual(after, "Done")
    }

    func testApprovalEventAddsPendingApprovalToItsCorrelatedWorkSession() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        let effects = reducer.receive(
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
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )

        XCTAssertEqual(effects, [])
        XCTAssertEqual(
            reducer.records["session-one"]?.pendingApprovals,
            [
                AgentHostApprovalRequest(
                    id: "approval-one",
                    toolCallId: "tool-one",
                    toolName: "write",
                    summary: #"{"path":"Sources/App.swift"}"#
                )
            ]
        )
        XCTAssertEqual(reducer.records["session-one"]?.lastSequence, 1)
    }

    func testStandardACPElicitationIsQueuedWithoutASequenceAndRemovedAfterResponse() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )
        let request = AgentHostACPElicitationRequest(
            id: "73",
            sessionId: "session-one",
            message: "Choose an action",
            schema: AgentHostACPElicitationSchema(
                properties: [
                    "value": AgentHostACPElicitationProperty(type: .string)
                ],
                required: ["value"]
            )
        )

        let effects = reducer.receive(
            .elicitationRequested(request),
            timestamp: "2026-08-29T00:00:00.000Z"
        )

        XCTAssertEqual(effects, [])
        XCTAssertEqual(reducer.records["session-one"]?.pendingElicitations, [request])
        XCTAssertEqual(reducer.records["session-one"]?.lastSequence, 0)

        reducer.resolveElicitation(sessionId: "session-one", requestId: request.id)
        XCTAssertEqual(reducer.records["session-one"]?.pendingElicitations, [])
    }

    func testApprovalIsAttachedToItsToolInsideTheTranscript() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        _ = reducer.receive(
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "write",
                    summary: #"{"path":"Sources/App.swift"}"#
                )
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )
        let request = AgentHostSessionApprovalRequestedPayload(
            sessionId: "session-one",
            sequence: 2,
            turnId: "turn-one",
            requestId: "approval-one",
            toolCallId: "tool-one",
            toolName: "write",
            summary: #"{"path":"Sources/App.swift"}"#
        )
        _ = reducer.receive(
            .sessionApprovalRequested(request),
            timestamp: "2026-08-09T00:00:02.000Z"
        )

        let waitingTool = try XCTUnwrap(
            reducer.records["session-one"]?.transcript
                .flatMap(\.parts)
                .compactMap { part -> SessionToolRecord? in
                    guard case .tool(let tool) = part else { return nil }
                    return tool
                }
                .first
        )
        XCTAssertEqual(waitingTool.state, .awaitingApproval)
        XCTAssertEqual(waitingTool.approval, request.approval)

        reducer.resolveApproval(sessionId: "session-one", requestId: "approval-one")

        let resumedTool = try XCTUnwrap(
            reducer.records["session-one"]?.transcript
                .flatMap(\.parts)
                .compactMap { part -> SessionToolRecord? in
                    guard case .tool(let tool) = part else { return nil }
                    return tool
                }
                .first
        )
        XCTAssertEqual(resumedTool.state, .running)
        XCTAssertNil(resumedTool.approval)
    }

    func testStructuredPluginStateSurvivesToolUpdates() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )
        let rawInput = AgentHostJSONValue.object([
            "agent": .string("reviewer"),
            "task": .string("Review changes")
        ])
        let rawOutput = AgentHostJSONValue.object([
            "mode": .string("single"),
            "results": .array([
                .object([
                    "agent": .string("reviewer"),
                    "task": .string("Review changes"),
                    "exitCode": .number(0)
                ])
            ])
        ])

        _ = reducer.receive(
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "subagent",
                    summary: "",
                    rawInput: rawInput
                )
            ),
            timestamp: "2026-08-29T00:00:00Z"
        )
        _ = reducer.receive(
            .sessionToolUpdated(
                AgentHostSessionToolUpdatedPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "subagent",
                    output: "running",
                    rawOutput: rawOutput
                )
            ),
            timestamp: "2026-08-29T00:00:01Z"
        )

        let tool = try XCTUnwrap(reducer.records["session-one"]?.tools.first)
        XCTAssertEqual(tool.rawInput, rawInput)
        XCTAssertEqual(tool.rawOutput, rawOutput)
    }

    func testExtensionStatusUpdatesAndClearsTheSessionProjection() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .work,
            sessionDirectory: nil
        )

        _ = reducer.receive(
            .sessionExtensionStatusChanged(
                AgentHostSessionExtensionStatusChangedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    key: "status-demo",
                    text: "Ready"
                )
            ),
            timestamp: "2026-08-29T00:00:00Z"
        )
        XCTAssertEqual(
            reducer.records["session-one"]?.acpState.extensionStatuses,
            ["status-demo": "Ready"]
        )

        _ = reducer.receive(
            .sessionExtensionStatusChanged(
                AgentHostSessionExtensionStatusChangedPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    key: "status-demo",
                    text: nil
                )
            ),
            timestamp: "2026-08-29T00:00:01Z"
        )
        XCTAssertEqual(reducer.records["session-one"]?.acpState.extensionStatuses, [:])
    }

    func testWidgetUpdatesReplaceOnlyTheirOwnKeyAndStayInTheirSession() throws {
        var reducer = SessionStoreReducer()
        for sessionId in ["session-one", "session-two"] {
            reducer.apply(snapshot: makeSnapshot(sessionId: sessionId), profile: .work, sessionDirectory: nil)
        }
        let updates = [
            #"{"key":"alpha","lines":["☐ Inspect"],"placement":"aboveEditor"}"#,
            #"{"key":"beta","lines":["2 workers running"],"placement":"belowEditor"}"#,
            #"{"key":"alpha","lines":["✓ Inspect","☐ Verify"]}"#,
            #"{"key":"beta"}"#
        ]
        for (index, json) in updates.enumerated() {
            var update = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            update["sessionUpdate"] = "_piWork/extension_widget"
            update["_meta"] = ["sequence": index + 1]
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "method": "session/update",
                "params": ["sessionId": "session-one", "update": update]
            ])
            XCTAssertEqual(reducer.receive(try AgentHostServerEvent.decode(from: data), timestamp: "now"), [])
        }
        XCTAssertEqual(reducer.records["session-one"]?.acpState.extensionWidgets, [
            "alpha": AgentHostExtensionWidget(lines: ["✓ Inspect", "☐ Verify"])
        ])
        XCTAssertEqual(reducer.records["session-two"]?.acpState.extensionWidgets, [:])
        XCTAssertNil(reducer.records["session-one"]?.acpState.plan)
    }

    func testSnapshotRestoresAndClearsWidgets() {
        var reducer = SessionStoreReducer()
        let widgets = ["alpha": AgentHostExtensionWidget(lines: ["Restored"], placement: .belowEditor)]
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one", extensionWidgets: widgets),
            profile: .work,
            sessionDirectory: nil
        )
        XCTAssertEqual(reducer.records["session-one"]?.acpState.extensionWidgets, widgets)
        reducer.apply(snapshot: makeSnapshot(sessionId: "session-one"), profile: .work, sessionDirectory: nil)
        XCTAssertEqual(reducer.records["session-one"]?.acpState.extensionWidgets, [:])
    }

    func testSnapshotPendingApprovalCreatesAnInlineToolPart() throws {
        let approval = AgentHostApprovalRequest(
            id: "approval-one",
            toolCallId: "tool-one",
            toolName: "bash",
            summary: "bun test"
        )
        var reducer = SessionStoreReducer()

        reducer.apply(
            snapshot: makeSnapshot(
                sessionId: "session-one",
                pendingApprovals: [approval]
            ),
            profile: .work,
            sessionDirectory: nil
        )

        let tool = try XCTUnwrap(
            reducer.records["session-one"]?.transcript
                .flatMap(\.parts)
                .compactMap { part -> SessionToolRecord? in
                    guard case .tool(let tool) = part else { return nil }
                    return tool
                }
                .first
        )
        XCTAssertEqual(tool.state, .awaitingApproval)
        XCTAssertEqual(tool.approval, approval)
    }

    func testSnapshotRestoresExtensionUIStateEmittedBeforeSessionCreationCompletes() {
        var reducer = SessionStoreReducer()
        let plan = [
            AgentHostACPPlanEntry(
                content: "Verify ACP plan",
                priority: .medium,
                status: .inProgress
            )
        ]

        reducer.apply(
            snapshot: makeSnapshot(
                sessionId: "session-one",
                extensionStatuses: ["status-demo": "Ready"],
                plan: plan
            ),
            profile: .work,
            sessionDirectory: nil
        )

        XCTAssertEqual(
            reducer.records["session-one"]?.acpState.extensionStatuses,
            ["status-demo": "Ready"]
        )
        XCTAssertEqual(reducer.records["session-one"]?.acpState.plan, plan)
    }

    func testSelectingAccessModeAndResolvingApprovalUpdatesProjection() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(
                sessionId: "session-one",
                pendingApprovals: [
                    AgentHostApprovalRequest(
                        id: "approval-one",
                        toolCallId: "tool-one",
                        toolName: "bash",
                        summary: "bun test"
                    )
                ]
            ),
            profile: .work,
            sessionDirectory: nil
        )

        reducer.selectAccessMode(sessionId: "session-one", accessMode: .full)
        XCTAssertEqual(reducer.records["session-one"]?.pendingApprovals, [])
        let inlineTool = reducer.records["session-one"]?.transcript
            .flatMap(\.parts)
            .compactMap { part -> SessionToolRecord? in
                guard case .tool(let tool) = part else { return nil }
                return tool
            }
            .first
        XCTAssertEqual(inlineTool?.state, .running)
        XCTAssertNil(inlineTool?.approval)
        reducer.resolveApproval(sessionId: "session-one", requestId: "approval-one")

        XCTAssertEqual(reducer.records["session-one"]?.accessMode, .full)
        XCTAssertEqual(reducer.records["session-one"]?.pendingApprovals, [])
    }

    func testSelectingModelOptionUpdatesCapabilityStateAndContextBudget() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            snapshot: makeSnapshot(sessionId: "session-one"),
            profile: .chat,
            sessionDirectory: nil
        )
        let model = AgentHostModel(
            provider: "openai",
            id: "gpt-5.6-sol",
            name: "GPT-5.6 Sol",
            contextWindow: 1_050_000,
            maxTokens: 128_000,
            reasoning: true,
            supportsImages: true
        )
        let usage = AgentHostContextUsage(
            tokens: 10_500,
            contextWindow: 1_050_000,
            percent: 1
        )
        let options = AgentHostModelOptions(
            fastMode: AgentHostModelOptionState(supported: true, enabled: true),
            oneMillionContext: AgentHostModelOptionState(supported: true, enabled: true)
        )

        reducer.selectModelOption(
            sessionId: "session-one",
            model: model,
            contextUsage: usage,
            modelOptions: options
        )

        XCTAssertEqual(reducer.records["session-one"]?.model, model)
        XCTAssertEqual(reducer.records["session-one"]?.contextUsage, usage)
        XCTAssertEqual(reducer.records["session-one"]?.modelOptions, options)
    }

    func testContextUsageFlowsFromSnapshotAndIdleEvent() {
        var reducer = SessionStoreReducer()
        let initialUsage = AgentHostContextUsage(
            tokens: 32_000,
            contextWindow: 128_000,
            percent: 25
        )
        let updatedUsage = AgentHostContextUsage(
            tokens: 96_000,
            contextWindow: 128_000,
            percent: 75
        )
        reducer.apply(
            snapshot: makeSnapshot(
                sessionId: "session-one",
                contextUsage: initialUsage
            ),
            profile: .chat,
            sessionDirectory: nil
        )

        let effects = reducer.receive(
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    turnId: "turn-one",
                    state: .idle,
                    contextUsage: updatedUsage
                )
            ),
            timestamp: "2026-08-09T00:00:01.000Z"
        )

        XCTAssertEqual(effects, [])
        XCTAssertEqual(reducer.records["session-one"]?.contextUsage, updatedUsage)
    }

    func testStandardACPStateUpdatesAreProjectedIntoTheSessionRecord() {
        var reducer = SessionStoreReducer()
        reducer.apply(
            SessionStoreReducer.project(
                summary: makeACPSummary(),
                profile: .work,
                sessionDirectory: nil
            )
        )
        let configOptions = makeACPState().configOptions
        let cost = AgentHostACPSessionCost(amount: 0.42, currency: "USD")
        let commands = [
            AgentHostACPAvailableCommand(name: "review", description: "Review changes")
        ]
        let plan = [
            AgentHostACPPlanEntry(content: "Inspect", priority: .high, status: .inProgress)
        ]

        _ = reducer.receive(
            .sessionModeChanged(
                AgentHostSessionModeChangedPayload(
                    sessionId: "session-one",
                    sequence: 1,
                    currentModeId: "full"
                )
            ),
            timestamp: "2026-08-29T00:00:00Z"
        )
        _ = reducer.receive(
            .sessionConfigOptionsChanged(
                AgentHostSessionConfigOptionsChangedPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    configOptions: configOptions
                )
            ),
            timestamp: "2026-08-29T00:00:00Z"
        )
        _ = reducer.receive(
            .sessionUsageChanged(
                AgentHostSessionUsageChangedPayload(
                    sessionId: "session-one",
                    sequence: 3,
                    used: 32,
                    size: 128,
                    cost: cost
                )
            ),
            timestamp: "2026-08-29T00:00:00Z"
        )
        _ = reducer.receive(
            .sessionAvailableCommandsChanged(
                AgentHostSessionAvailableCommandsChangedPayload(
                    sessionId: "session-one",
                    sequence: 4,
                    availableCommands: commands
                )
            ),
            timestamp: "2026-08-29T00:00:00Z"
        )
        _ = reducer.receive(
            .sessionPlanChanged(
                AgentHostSessionPlanChangedPayload(
                    sessionId: "session-one",
                    sequence: 5,
                    entries: plan
                )
            ),
            timestamp: "2026-08-29T00:00:00Z"
        )
        _ = reducer.receive(
            .sessionInfoChanged(
                AgentHostSessionInfoChangedPayload(
                    sessionId: "session-one",
                    sequence: 6,
                    title: "Renamed",
                    updatedAt: "2026-08-29T00:00:00Z"
                )
            ),
            timestamp: "2026-08-29T00:00:00Z"
        )

        let record = reducer.records["session-one"]
        XCTAssertEqual(record?.accessMode, .full)
        XCTAssertEqual(record?.model?.id, "opus")
        XCTAssertEqual(record?.model?.contextWindow, 128)
        XCTAssertEqual(record?.thinkingLevel, .high)
        XCTAssertEqual(record?.contextUsage?.tokens, 32)
        XCTAssertEqual(record?.contextUsage?.contextWindow, 128)
        XCTAssertEqual(record?.contextUsage?.percent, 25)
        XCTAssertEqual(record?.acpState.cost, cost)
        XCTAssertEqual(record?.acpState.availableCommands, commands)
        XCTAssertEqual(record?.acpState.plan, plan)
        XCTAssertEqual(record?.descriptor.title, "Renamed")
        XCTAssertEqual(record?.acpState.updatedAt, "2026-08-29T00:00:00Z")
    }
}

private func makeSnapshot(
    sessionId: String,
    messages: [AgentHostSessionMessage] = [],
    pendingApprovals: [AgentHostApprovalRequest] = [],
    contextUsage: AgentHostContextUsage? = nil,
    extensionStatuses: [String: String] = [:],
    extensionWidgets: [String: AgentHostExtensionWidget] = [:],
    plan: [AgentHostACPPlanEntry]? = nil
) -> AgentHostSessionSnapshotResult {
    AgentHostSessionSnapshotResult(
        session: AgentHostSessionDescriptor(
            id: sessionId,
            path: "/tmp/\(sessionId).jsonl",
            cwd: "/tmp/project",
            title: "New Session"
        ),
        messages: messages,
        state: .idle,
        sequence: 0,
        turnId: nil,
        model: nil,
        contextUsage: contextUsage,
        thinkingLevel: .off,
        availableThinkingLevels: [],
        accessMode: .ask,
        pendingApprovals: pendingApprovals,
        extensionStatuses: extensionStatuses,
        extensionWidgets: extensionWidgets,
        plan: plan
    )
}

private func assistantContent(
    sequence: Int,
    generationIndex: Int,
    phase: AgentHostAssistantContentPhase,
    contentType: AgentHostAssistantContentType,
    contentIndex: Int,
    delta: String? = nil,
    content: String? = nil,
    toolCall: AgentHostAssistantToolCall? = nil
) -> AgentHostServerEvent {
    .sessionAssistantContent(
        AgentHostSessionAssistantContentPayload(
            sessionId: "session-one",
            sequence: sequence,
            turnId: "turn-one",
            generationIndex: generationIndex,
            phase: phase,
            contentType: contentType,
            contentIndex: contentIndex,
            delta: delta,
            content: content,
            toolCall: toolCall
        )
    )
}

private func makeACPSummary() -> AgentHostSessionSummary {
    AgentHostSessionSummary(
        id: "session-one",
        path: "session-one",
        cwd: "/tmp/project",
        title: "Session",
        firstMessage: "",
        messageCount: 0,
        createdAt: "2026-08-29T00:00:00Z",
        modifiedAt: "2026-08-29T00:00:00Z"
    )
}

private func makeACPState() -> AgentHostACPSessionState {
    AgentHostACPSessionState(
        modes: AgentHostACPSessionModeState(
            currentModeId: "ask",
            availableModes: [
                AgentHostACPSessionMode(id: "ask", name: "Ask", description: nil),
                AgentHostACPSessionMode(id: "full", name: "Full", description: nil)
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
