import XCTest
@testable import PiWork

final class AssistantTimelinePresentationTests: XCTestCase {
    func testActivityPresentationKeepsProgressAndUnknownMessagesWhenRemovingUpdateSuffixes() {
        XCTAssertEqual(SessionActivityPresentation.statusForDisplay(
            " bg 2 running · worker · ↑ v2.5.0 /bg-update "
        ), "bg 2 running · worker")
        XCTAssertEqual(SessionActivityPresentation.statusForDisplay(
            "Running ↑ v2.5.0 /helper-update"
        ), "Running")
        XCTAssertEqual(SessionActivityPresentation.statusForDisplay("Upgrade available"), "Upgrade available")
        XCTAssertEqual(SessionActivityPresentation.statusForDisplay("Release v1.2.3 /publish"), "Release v1.2.3 /publish")
        XCTAssertNil(SessionActivityPresentation.statusForDisplay(" ⬆️ v2.5.0 /update "))
        XCTAssertNil(SessionActivityPresentation.statusForDisplay("  \n "))
    }

    func testActivityPresentationDeduplicatesWidgetStatusAndPreservesGenericText() {
        let activity = SessionActivityPresentation(
            plan: [], statuses: ["arbitrary": "Tasks (1/2)"],
            widgets: ["arbitrary": AgentHostExtensionWidget(lines: [
                "", "Tasks (1/2)", "  └─ worker running", ""
            ])]
        )
        XCTAssertEqual(activity.items.count, 1)
        XCTAssertNil(activity.items.first?.status)
        XCTAssertEqual(activity.items.first?.lines, ["Tasks (1/2)", "  └─ worker running"])
        XCTAssertTrue(activity.canExpand)
        XCTAssertEqual(activity.summary, "Tasks (1/2)")
        XCTAssertTrue(activity.plan.isEmpty, "Widget text must not become an ACP plan")
    }

    func testActivityPresentationKeepsACPPlanIndependentAndOrdersWidgetPlacements() {
        let plan = [AgentHostACPPlanEntry(content: "Current step", priority: .medium, status: .inProgress)]
        let activity = SessionActivityPresentation(
            plan: plan, statuses: ["b": "Ready"], widgets: [
                "a": AgentHostExtensionWidget(lines: ["Footer"], placement: .belowEditor),
                "c": AgentHostExtensionWidget(lines: ["Header"], placement: .aboveEditor)
            ]
        )
        XCTAssertEqual(activity.plan, plan)
        XCTAssertEqual(activity.summary, "Current step")
        XCTAssertEqual(activity.items.map(\.id), ["b", "c", "a"])
        XCTAssertTrue(activity.canExpand)
        XCTAssertFalse(SessionActivityPresentation(plan: [], statuses: ["a": "Ready"], widgets: [:]).canExpand)
    }

    func testSessionPresentationGrowsFromACompactFirstFrameToTheRequestedWindow() {
        XCTAssertEqual(SessionPresentationBatch.initialCount, 4)
        XCTAssertEqual(SessionPresentationBatch.growthCount, 12)
        XCTAssertEqual(SessionPresentationBatch.nextLimit(current: 4, target: 40), 16)
        XCTAssertEqual(SessionPresentationBatch.nextLimit(current: 28, target: 35), 35)
        XCTAssertEqual(SessionPresentationBatch.nextLimit(current: 40, target: 40), 40)
    }

    func testTranscriptWindowInitiallyKeepsOnlyNewestMessages() {
        let messages = (0..<75).map { index in
            PiChatMessage(id: "message-\(index)", role: .user, text: "Message \(index)")
        }

        let window = TranscriptWindow(messages: messages)

        XCTAssertEqual(window.messages.count, TranscriptWindow.batchSize)
        XCTAssertEqual(window.messages.first?.id, "message-35")
        XCTAssertEqual(window.hiddenCount, 35)
    }

    func testTranscriptWindowCanRevealOneOlderBatch() {
        let messages = (0..<95).map { index in
            PiChatMessage(id: "message-\(index)", role: .user, text: "Message \(index)")
        }

        let window = TranscriptWindow(
            messages: messages,
            limit: TranscriptWindow.batchSize * 2
        )

        XCTAssertEqual(window.messages.count, 80)
        XCTAssertEqual(window.messages.first?.id, "message-15")
        XCTAssertEqual(window.hiddenCount, 15)
    }

    func testTranscriptProjectionBoundsSourceBeforeBuildingChatMessages() {
        let transcript = (0..<95).map { index in
            SessionTranscriptMessage(
                id: "message-\(index)",
                role: .user,
                parts: [.text(id: "text-\(index)", text: "Message \(index)")],
                timestamp: ""
            )
        }

        let sourceWindow = TranscriptProjection.sourceWindow(
            transcript,
            limit: TranscriptWindow.batchSize
        )

        XCTAssertEqual(sourceWindow.messages.count, 40)
        XCTAssertEqual(sourceWindow.messages.first?.id, "message-55")
        XCTAssertEqual(sourceWindow.hiddenCount, 55)
    }

    func testTranscriptProjectionReturnsNewestVisibleMessages() {
        let messages = (0..<90).map { index in
            SessionTranscriptMessage(
                id: "message-\(index)",
                role: .user,
                parts: [.text(id: "text-\(index)", text: "Message \(index)")],
                timestamp: ""
            )
        }

        let window = TranscriptProjection.recentMessages(
            messages,
            limit: TranscriptWindow.batchSize
        ) { message in
            let index = Int(message.id.components(separatedBy: "-").last ?? "") ?? 0
            return index.isMultiple(of: 2) ? message.id : nil
        }

        XCTAssertEqual(window.messages.count, 40)
        XCTAssertEqual(window.messages.first, "message-10")
        XCTAssertEqual(window.messages.last, "message-88")
        XCTAssertEqual(window.hiddenCount, 10)
    }

    func testAdjacentToolOnlyAssistantGenerationsShareOneMessageRow() throws {
        let first = makeTool(id: "first", state: .completed, isError: false)
        let second = makeTool(id: "second", state: .completed, isError: false)
        let messages = [
            makeAssistantMessage(id: "assistant-one", parts: [.tool(first)]),
            makeAssistantMessage(id: "assistant-two", parts: [.tool(second)])
        ]

        let grouped = AssistantTranscriptPresentation.groupAdjacentTools(in: messages)

        let message = try XCTUnwrap(grouped.first)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(message.id, "assistant-one")
        XCTAssertEqual(message.parts, [.tool(first), .tool(second)])
        XCTAssertEqual(
            AssistantTranscriptPresentation.blocks(from: message.parts),
            [.tools(AssistantToolGroup(id: "tool-group:first", tools: [first, second]))]
        )
    }

    func testVisibleThinkingSeparatesToolOnlyAssistantGenerations() {
        let first = makeTool(id: "first", state: .completed, isError: false)
        let second = makeTool(id: "second", state: .completed, isError: false)
        let thinking = SessionThinkingRecord(
            id: "thinking",
            text: "Checking the result",
            state: .completed,
            redacted: false
        )
        let messages = [
            makeAssistantMessage(id: "assistant-one", parts: [.tool(first)]),
            makeAssistantMessage(id: "assistant-thinking", parts: [.thinking(thinking)]),
            makeAssistantMessage(id: "assistant-two", parts: [.tool(second)])
        ]

        let grouped = AssistantTranscriptPresentation.groupAdjacentTools(in: messages)

        XCTAssertEqual(
            grouped.map(\.id),
            ["assistant-one", "assistant-thinking", "assistant-two"]
        )
    }

    func testToolOnlyGenerationJoinsPreviousAssistantThatEndsWithATool() throws {
        let first = makeTool(id: "first", state: .completed, isError: false)
        let second = makeTool(id: "second", state: .completed, isError: false)
        let messages = [
            makeAssistantMessage(
                id: "assistant-one",
                parts: [
                    .text(id: "intro", text: "开始执行。"),
                    .tool(first)
                ]
            ),
            makeAssistantMessage(id: "assistant-two", parts: [.tool(second)])
        ]

        let grouped = AssistantTranscriptPresentation.groupAdjacentTools(in: messages)

        let message = try XCTUnwrap(grouped.first)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(
            message.parts,
            [.text(id: "intro", text: "开始执行。"), .tool(first), .tool(second)]
        )
        XCTAssertEqual(
            AssistantTranscriptPresentation.blocks(from: message.parts),
            [
                .text(id: "intro", text: "开始执行。"),
                .tools(AssistantToolGroup(id: "tool-group:first", tools: [first, second]))
            ]
        )
    }

    func testConsecutiveToolsAreGroupedUntilVisibleContentSeparatesThem() {
        let first = makeTool(id: "first", state: .completed, isError: false)
        let second = makeTool(id: "second", state: .running)
        let third = makeTool(id: "third", state: .completed, isError: false)

        let blocks = AssistantTranscriptPresentation.blocks(from: [
            .text(id: "intro", text: "先检查项目。"),
            .tool(first),
            .tool(second),
            .text(id: "update", text: "接下来修改文件。"),
            .tool(third)
        ])

        XCTAssertEqual(blocks, [
            .text(id: "intro", text: "先检查项目。"),
            .tools(AssistantToolGroup(id: "tool-group:first", tools: [first, second])),
            .text(id: "update", text: "接下来修改文件。"),
            .tools(AssistantToolGroup(id: "tool-group:third", tools: [third]))
        ])
    }

    func testToolGroupIdentityStaysStableWhenStreamingAppendsAnotherTool() throws {
        let first = makeTool(id: "first", state: .running)
        let second = makeTool(id: "second", state: .running)

        let initial = AssistantTranscriptPresentation.blocks(from: [.tool(first)])
        let updated = AssistantTranscriptPresentation.blocks(from: [.tool(first), .tool(second)])

        XCTAssertEqual(try XCTUnwrap(initial.first?.id), try XCTUnwrap(updated.first?.id))
    }

    func testMessageMetadataAnchorsToTheLastTextInsteadOfATrailingToolGroup() {
        let blocks = AssistantTranscriptPresentation.blocks(from: [
            .text(id: "answer", text: "请先完成人机验证。"),
            .tool(makeTool(id: "browser", state: .completed, isError: false))
        ])

        XCTAssertEqual(
            AssistantTranscriptPresentation.metadataAnchorID(in: blocks),
            "answer"
        )
    }

    func testHiddenThinkingDoesNotSplitConsecutiveToolGroups() {
        let first = makeTool(id: "first", state: .completed, isError: false)
        let second = makeTool(id: "second", state: .completed, isError: false)
        let thinking = SessionThinkingRecord(
            id: "thinking",
            text: "",
            state: .completed,
            redacted: false
        )

        let blocks = AssistantTranscriptPresentation.blocks(from: [
            .tool(first),
            .thinking(thinking),
            .tool(second)
        ])

        XCTAssertEqual(blocks, [
            .tools(AssistantToolGroup(id: "tool-group:first", tools: [first, second]))
        ])
    }

    func testCompletedThinkingWithContentRemainsAvailableAsAnExpandableBlock() {
        let thinking = SessionThinkingRecord(
            id: "thinking",
            text: "Checked the available APIs.",
            state: .completed,
            redacted: false
        )

        XCTAssertEqual(
            AssistantTranscriptPresentation.blocks(from: [.thinking(thinking)]),
            [.thinking(thinking)]
        )
    }

    func testRunningThinkingWithoutTextDoesNotCreateATransientBlock() {
        let thinking = SessionThinkingRecord(
            id: "thinking",
            text: "",
            state: .running,
            redacted: false
        )

        XCTAssertEqual(
            AssistantTranscriptPresentation.blocks(from: [.thinking(thinking)]),
            []
        )
    }

    func testRunningThinkingRemainsVisibleBetweenToolGroups() {
        let first = makeTool(id: "first", state: .completed, isError: false)
        let second = makeTool(id: "second", state: .running)
        let thinking = SessionThinkingRecord(
            id: "thinking",
            text: "Inspecting sources",
            state: .running,
            redacted: false
        )

        let blocks = AssistantTranscriptPresentation.blocks(from: [
            .tool(first),
            .thinking(thinking),
            .tool(second)
        ])

        XCTAssertEqual(blocks, [
            .tools(AssistantToolGroup(id: "tool-group:first", tools: [first])),
            .thinking(thinking),
            .tools(AssistantToolGroup(id: "tool-group:second", tools: [second]))
        ])
    }

    func testTaggedThinkingTextBecomesAThinkingBlockBeforeTheResponseAndTool() {
        let tool = makeTool(id: "read", state: .running)
        let blocks = AssistantTranscriptPresentation.blocks(from: [
            .text(
                id: "legacy",
                text: "<think>Inspecting sources</think>\n\nStarting the tool."
            ),
            .tool(tool)
        ])

        XCTAssertEqual(blocks, [
            .thinking(
                SessionThinkingRecord(
                    id: "legacy:thinking",
                    text: "Inspecting sources",
                    state: .completed,
                    redacted: false
                )
            ),
            .text(id: "legacy:response", text: "Starting the tool."),
            .tools(AssistantToolGroup(id: "tool-group:read", tools: [tool]))
        ])
    }

    func testUnclosedTaggedThinkingTextRemainsAStreamingThinkingBlock() {
        let blocks = AssistantTranscriptPresentation.blocks(from: [
            .text(id: "legacy", text: "<think>Inspecting sources")
        ])

        XCTAssertEqual(blocks, [
            .thinking(
                SessionThinkingRecord(
                    id: "legacy:thinking",
                    text: "Inspecting sources",
                    state: .running,
                    redacted: false
                )
            )
        ])
    }

    func testRunningStatusReportsFinishedAndTotalSteps() {
        let group = AssistantToolGroup(id: "group", tools: [
            makeTool(id: "done", state: .completed, isError: false),
            makeTool(id: "active", state: .running)
        ])

        XCTAssertEqual(group.status, .running(completed: 1, total: 2))
    }

    func testApprovalStatusTakesPriorityOverRunningSteps() {
        let approval = AgentHostApprovalRequest(
            id: "approval",
            toolCallId: "waiting",
            toolName: "bash",
            summary: "bun test"
        )
        let group = AssistantToolGroup(id: "group", tools: [
            makeTool(id: "active", state: .running),
            makeTool(id: "waiting", state: .awaitingApproval, approval: approval)
        ])

        XCTAssertEqual(group.status, .approvalRequired)
    }

    func testFailedStatusCountsTerminalErrors() {
        let group = AssistantToolGroup(id: "group", tools: [
            makeTool(id: "done", state: .completed, isError: false),
            makeTool(id: "failed", state: .completed, isError: true)
        ])

        XCTAssertEqual(group.status, .failed(total: 2, failed: 1))
    }

    func testCompletedStatusRequiresEveryStepToSucceed() {
        let group = AssistantToolGroup(id: "group", tools: [
            makeTool(id: "first", state: .completed, isError: false),
            makeTool(id: "second", state: .completed, isError: false)
        ])

        XCTAssertEqual(group.status, .completed(total: 2))
    }

    func testCancelledStatusRepresentsInterruptedGroups() {
        let group = AssistantToolGroup(id: "group", tools: [
            makeTool(id: "done", state: .completed, isError: false),
            makeTool(id: "cancelled", state: .cancelled)
        ])

        XCTAssertEqual(group.status, .cancelled(total: 2))
    }

    func testOnlyActiveApprovalAndFailedGroupsPreferExpansion() {
        XCTAssertTrue(AssistantToolGroupStatus.running(completed: 0, total: 1).prefersExpanded)
        XCTAssertTrue(AssistantToolGroupStatus.approvalRequired.prefersExpanded)
        XCTAssertTrue(AssistantToolGroupStatus.failed(total: 1, failed: 1).prefersExpanded)
        XCTAssertFalse(AssistantToolGroupStatus.completed(total: 1).prefersExpanded)
        XCTAssertFalse(AssistantToolGroupStatus.cancelled(total: 1).prefersExpanded)
    }

    func testToolOutputFallsBackToGenericRawOutput() {
        let rawOutput: AgentHostJSONValue = .object([
            "plugin": .string("any-extension"),
            "state": .string("running")
        ])

        XCTAssertEqual(
            toolOutputForDisplay(output: "", rawOutput: rawOutput),
            "{\n  \"plugin\" : \"any-extension\",\n  \"state\" : \"running\"\n}"
        )
        XCTAssertEqual(
            toolOutputForDisplay(output: "plain output", rawOutput: rawOutput),
            "plain output"
        )
    }

    func testApprovalCannotBeHiddenByManualCollapse() {
        XCTAssertTrue(
            AssistantToolGroupStatus.approvalRequired.isExpanded(
                manualSelection: false
            )
        )
        XCTAssertFalse(
            AssistantToolGroupStatus.running(completed: 0, total: 1).isExpanded(
                manualSelection: false
            )
        )
    }

    func testTranscriptIsNearBottomWithinThreshold() {
        XCTAssertTrue(
            TranscriptScrollPresentation.isNearBottom(
                bottomY: 660,
                viewportHeight: 600,
                threshold: 72
            )
        )
        XCTAssertFalse(
            TranscriptScrollPresentation.isNearBottom(
                bottomY: 673,
                viewportHeight: 600,
                threshold: 72
            )
        )
    }

    func testTranscriptScrollerIsNearBottomWithinPointThreshold() {
        XCTAssertTrue(
            TranscriptScrollPresentation.isNearBottom(
                scrollPosition: 0.999,
                scrollableDistance: 10_000,
                threshold: 72
            )
        )
        XCTAssertFalse(
            TranscriptScrollPresentation.isNearBottom(
                scrollPosition: 0.98,
                scrollableDistance: 10_000,
                threshold: 72
            )
        )
    }

    func testHistoryAutoLoadTriggersOnceWhenUserScrollsNearTop() {
        var trigger = TranscriptHistoryLoadTrigger()

        XCTAssertTrue(trigger.update(
            distanceFromTop: 80,
            isUserScrolling: true,
            hasEarlierMessages: true,
            threshold: 160
        ))
        XCTAssertFalse(trigger.update(
            distanceFromTop: 60,
            isUserScrolling: true,
            hasEarlierMessages: true,
            threshold: 160
        ))
    }

    func testHistoryAutoLoadRearmsAfterLeavingTopThreshold() {
        var trigger = TranscriptHistoryLoadTrigger()
        _ = trigger.update(
            distanceFromTop: 80,
            isUserScrolling: true,
            hasEarlierMessages: true,
            threshold: 160
        )

        XCTAssertFalse(trigger.update(
            distanceFromTop: 240,
            isUserScrolling: true,
            hasEarlierMessages: true,
            threshold: 160
        ))
        XCTAssertTrue(trigger.update(
            distanceFromTop: 100,
            isUserScrolling: true,
            hasEarlierMessages: true,
            threshold: 160
        ))
    }

    func testHistoryAutoLoadDoesNotTriggerForProgrammaticScrolling() {
        var trigger = TranscriptHistoryLoadTrigger()

        XCTAssertFalse(trigger.update(
            distanceFromTop: 0,
            isUserScrolling: false,
            hasEarlierMessages: true,
            threshold: 160
        ))
    }

    func testHistoryAutoLoadResetsWhenNoEarlierMessagesRemain() {
        var trigger = TranscriptHistoryLoadTrigger()
        _ = trigger.update(
            distanceFromTop: 0,
            isUserScrolling: true,
            hasEarlierMessages: true,
            threshold: 160
        )
        _ = trigger.update(
            distanceFromTop: 0,
            isUserScrolling: true,
            hasEarlierMessages: false,
            threshold: 160
        )

        XCTAssertTrue(trigger.update(
            distanceFromTop: 0,
            isUserScrolling: true,
            hasEarlierMessages: true,
            threshold: 160
        ))
    }

    func testReturningToBottomResumesPausedTranscriptAutoFollow() {
        let updated = TranscriptScrollPresentation.updatedAutoFollowState(
            current: TranscriptAutoFollowState(
                isFollowingTail: false,
                isPaused: true
            ),
            bottomY: 620,
            viewportHeight: 600,
            threshold: 72,
            isAdjustingScroll: false
        )

        XCTAssertEqual(
            updated,
            TranscriptAutoFollowState(
                isFollowingTail: true,
                isPaused: false
            )
        )
    }

    func testMovingAwayFromBottomStopsFollowingAfterResume() {
        let updated = TranscriptScrollPresentation.updatedAutoFollowState(
            current: TranscriptAutoFollowState(
                isFollowingTail: true,
                isPaused: false
            ),
            bottomY: 800,
            viewportHeight: 600,
            threshold: 72,
            isAdjustingScroll: false
        )

        XCTAssertEqual(
            updated,
            TranscriptAutoFollowState(
                isFollowingTail: false,
                isPaused: false
            )
        )
    }

    func testConversationUsesToolGroupsAndManualScrollRecovery() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("AssistantTranscriptPresentation.blocks(from: message.parts)"))
        XCTAssertTrue(source.contains("AssistantToolGroupView("))
        XCTAssertTrue(source.contains("TranscriptBottomPreferenceKey"))
        XCTAssertTrue(source.contains("TranscriptScrollPresentation.updatedAutoFollowState"))
        XCTAssertTrue(source.contains("L10n.string(\"chat.scroll_to_latest\")"))
        XCTAssertTrue(source.contains("AssistantThinkingView("))
        XCTAssertTrue(source.contains("chat.thinking.running"))
        XCTAssertFalse(source.contains("chat.thinking.completed"))
        XCTAssertTrue(source.contains("chat.thinking.title"))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("State(initialValue: thinking.state == .running)"))

        let thinkingStart = try XCTUnwrap(source.range(of: "private struct AssistantThinkingView"))
        let toolGroupStart = try XCTUnwrap(source.range(of: "private struct AssistantToolGroupView"))
        let thinkingSource = String(source[thinkingStart.lowerBound..<toolGroupStart.lowerBound])
        XCTAssertTrue(thinkingSource.contains("Text(verbatim: thinking.text)"))
        XCTAssertFalse(thinkingSource.contains("Markdown(thinking.text)"))
        XCTAssertFalse(thinkingSource.contains(".transition("))
        XCTAssertFalse(thinkingSource.contains("withAnimation("))
    }

    func testUserScrollPausesTranscriptAutoFollowUntilReturningToBottomOrExplicitResume() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let scrollStart = try XCTUnwrap(
            source.range(of: "private func scrollToTranscriptTail")
        )
        let scrollEnd = try XCTUnwrap(
            source.range(of: "private var emptySession", range: scrollStart.upperBound..<source.endIndex)
        )
        let scrollSource = source[scrollStart.lowerBound..<scrollEnd.lowerBound]

        XCTAssertTrue(source.contains("@State private var isTranscriptAutoFollowPaused = false"))
        XCTAssertTrue(source.contains("TranscriptUserScrollObserver"))
        XCTAssertTrue(source.contains("NSScrollView.willStartLiveScrollNotification"))
        XCTAssertTrue(source.contains("NSView.boundsDidChangeNotification"))
        XCTAssertTrue(source.contains("onScrollPositionChange"))
        XCTAssertTrue(source.contains("isTranscriptAutoFollowPaused = true"))
        XCTAssertTrue(source.contains("TranscriptScrollPresentation.updatedAutoFollowState"))
        XCTAssertTrue(source.contains("isTranscriptAutoFollowPaused = updated.isPaused"))
        XCTAssertTrue(source.contains(
            "guard isFollowingTranscriptTail, !isTranscriptAutoFollowPaused else { return }"
        ))
        XCTAssertTrue(scrollSource.contains("isTranscriptAutoFollowPaused = false"))
        XCTAssertTrue(scrollSource.contains("isFollowingTranscriptTail = true"))
        XCTAssertFalse(scrollSource.contains(
            "DispatchQueue.main.async {\n            isFollowingTranscriptTail = true"
        ))
    }

    func testAssistantTextAlignsWithToolAndThinkingIconColumn() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let blockStart = try XCTUnwrap(source.range(of: "private func assistantBlock"))
        let thinkingCase = try XCTUnwrap(
            source.range(of: "case .thinking", range: blockStart.upperBound..<source.endIndex)
        )
        let textBlockSource = source[blockStart.lowerBound..<thinkingCase.lowerBound]

        XCTAssertTrue(textBlockSource.contains(".padding(.leading, 6)"))
    }

    func testConversationKeepsBoundedTranscriptRowsMountedWhileScrolling() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        let transcriptStart = try XCTUnwrap(source.range(of: "private func transcript("))
        let emptySessionStart = try XCTUnwrap(source.range(of: "private var emptySession: some View"))
        let transcriptSource = String(source[transcriptStart.lowerBound..<emptySessionStart.lowerBound])

        XCTAssertTrue(transcriptSource.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertFalse(transcriptSource.contains("LazyVStack(alignment: .leading, spacing: 12)"))
    }

    func testAssistantTimelineUsesOneThirdTighterVerticalRhythm() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let timelineStart = try XCTUnwrap(source.range(of: "private var assistantTimeline"))
        let timelineEnd = try XCTUnwrap(
            source.range(of: "private var assistantBlocks", range: timelineStart.upperBound..<source.endIndex)
        )
        let timelineSource = source[timelineStart.lowerBound..<timelineEnd.lowerBound]

        XCTAssertTrue(timelineSource.contains("VStack(alignment: .leading, spacing: 11)"))
        XCTAssertTrue(timelineSource.contains(".padding(.vertical, 3)"))
    }

    func testToolGroupHeaderUsesLeadingAlignedContent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let toolGroupStart = try XCTUnwrap(
            source.range(of: "private struct AssistantToolGroupView")
        )
        let toolStepStart = try XCTUnwrap(
            source.range(of: "private struct AssistantToolStepRow")
        )
        let toolGroupSource = String(
            source[toolGroupStart.lowerBound..<toolStepStart.lowerBound]
        )
        let labelStart = try XCTUnwrap(toolGroupSource.range(of: "} label: {"))
        let expandedContentStart = try XCTUnwrap(
            toolGroupSource.range(of: "if isExpanded {")
        )
        let headerSource = String(
            toolGroupSource[labelStart.lowerBound..<expandedContentStart.lowerBound]
        )

        XCTAssertFalse(headerSource.contains("Spacer("))
        XCTAssertTrue(
            headerSource.contains(".frame(maxWidth: .infinity, alignment: .leading)")
        )
    }

    func testToolStepRowsUseIconsThatMatchTheirToolType() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Image(systemName: presentation.iconName)"))
        XCTAssertTrue(source.contains("case \"read\": return \"book\""))
        XCTAssertTrue(source.contains("case \"bash\": return \"terminal\""))
        XCTAssertTrue(source.contains(
            "case \"write\", \"edit\": return \"square.and.pencil\""
        ))
        XCTAssertTrue(source.contains("case \"grep\", \"find\": return \"magnifyingglass\""))
        XCTAssertTrue(source.contains("case \"ls\": return \"folder\""))
        XCTAssertTrue(source.contains("case \"web_search\": return \"magnifyingglass\""))
        XCTAssertTrue(source.contains(
            "case \"web_fetch\", \"fetch_content\": return \"globe\""
        ))
    }

    func testFailedToolGroupUsesNeutralCheckAndOnlyToolIconShowsFailureInRed() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let toolGroupStart = try XCTUnwrap(
            source.range(of: "private struct AssistantToolGroupView")
        )
        let toolStepStart = try XCTUnwrap(
            source.range(of: "private struct AssistantToolStepRow")
        )
        let toolDetailStart = try XCTUnwrap(
            source.range(of: "private struct ToolDetailBlock")
        )
        let toolGroupSource = String(
            source[toolGroupStart.lowerBound..<toolStepStart.lowerBound]
        )
        let toolStepSource = String(
            source[toolStepStart.lowerBound..<toolDetailStart.lowerBound]
        )

        XCTAssertTrue(toolGroupSource.contains("case .failed, .completed:"))
        XCTAssertTrue(toolGroupSource.contains("Image(systemName: \"checkmark.circle\")"))
        XCTAssertTrue(toolGroupSource.contains(".font(.system(size: 12, weight: .medium))"))
        XCTAssertTrue(toolGroupSource.contains(".foregroundStyle(Color.primary.opacity(0.32))"))
        XCTAssertTrue(toolGroupSource.contains(
            "case .failed(let total, _):\n            return L10n.format(\"chat.steps.completed\", total)"
        ))
        XCTAssertTrue(toolStepSource.contains(
            "private var showsExceptionalStatus: Bool {\n        tool.state == .awaitingApproval\n    }"
        ))
        XCTAssertTrue(toolStepSource.contains("if tool.isError == true { return .red }"))
    }

    func testWriteAndEditUseTheStandardToolIconSize() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".font(.system(size: 12))"))
        XCTAssertFalse(source.contains("var iconFont: Font"))
    }

    func testToolOnlyAssistantMessageHasNoCopyableText() {
        let message = PiChatMessage(
            message: SessionTranscriptMessage(
                id: "tool-only",
                role: .assistant,
                parts: [
                    .tool(makeTool(id: "read", state: .completed, isError: false))
                ],
                timestamp: "2026-08-09T15:19:00.000Z"
            )
        )

        XCTAssertEqual(message.copyableText, "")
        XCTAssertFalse(message.hasCopyableText)
    }

    func testCopyableTextOmitsTaggedThinkingContent() {
        let message = PiChatMessage(
            message: SessionTranscriptMessage(
                id: "legacy-thinking",
                role: .assistant,
                parts: [
                    .text(
                        id: "legacy",
                        text: "<think>Private working notes</think>\n\nVisible answer"
                    )
                ],
                timestamp: "2026-08-09T15:19:00.000Z"
            )
        )

        XCTAssertEqual(message.copyableText, "Visible answer")
    }

    func testCompletedThinkingWithoutDisplayableTextDoesNotCreateAVisibleMessage() {
        let message = PiChatMessage(
            message: SessionTranscriptMessage(
                id: "redacted-thinking",
                role: .assistant,
                parts: [
                    .thinking(
                        SessionThinkingRecord(
                            id: "thinking",
                            text: "",
                            state: .completed,
                            redacted: true
                        )
                    )
                ],
                timestamp: "2026-08-09T15:19:00.000Z"
            )
        )

        XCTAssertFalse(message.isVisible)
    }

    func testCopyableTextOmitsToolsBetweenAssistantTextBlocks() {
        let message = PiChatMessage(
            message: SessionTranscriptMessage(
                id: "mixed",
                role: .assistant,
                parts: [
                    .text(id: "before", text: "开始分析。"),
                    .tool(makeTool(id: "read", state: .completed, isError: false)),
                    .text(id: "after", text: "分析完成。")
                ],
                timestamp: "2026-08-09T15:19:00.000Z"
            )
        )

        XCTAssertEqual(message.copyableText, "开始分析。\n分析完成。")
        XCTAssertTrue(message.hasCopyableText)
    }

    func testAssistantMetadataIsRenderedOnlyForCopyableMessageText() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("guard message.hasCopyableText else { return nil }")
        )
        XCTAssertTrue(source.contains("MessageClipboard.copy(message.copyableText)"))
    }

    func testAssistantMetadataOnlyAppearsWhileItsTextIsHovered() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let rowStart = try XCTUnwrap(source.range(of: "private struct ChatMessageRow"))
        let rowEnd = try XCTUnwrap(
            source.range(of: "private struct SkillUsageRow", range: rowStart.upperBound..<source.endIndex)
        )
        let rowSource = source[rowStart.lowerBound..<rowEnd.lowerBound]

        XCTAssertTrue(rowSource.contains("@State private var isAssistantMetadataHovered = false"))
        XCTAssertTrue(rowSource.contains(".opacity(isAssistantMetadataHovered ? 1 : 0)"))
        XCTAssertTrue(rowSource.contains(".allowsHitTesting(isAssistantMetadataHovered)"))
        XCTAssertTrue(rowSource.contains(".accessibilityHidden(!isAssistantMetadataHovered)"))
        XCTAssertTrue(rowSource.contains("isAssistantMetadataHovered = hovering"))
    }

    func testUserMessageMetadataAppearsWhileItsBubbleIsHovered() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let rowStart = try XCTUnwrap(source.range(of: "private struct ChatMessageRow"))
        let rowEnd = try XCTUnwrap(
            source.range(of: "private struct SkillUsageRow", range: rowStart.upperBound..<source.endIndex)
        )
        let rowSource = source[rowStart.lowerBound..<rowEnd.lowerBound]

        XCTAssertTrue(rowSource.contains("@State private var isUserMetadataHovered = false"))
        XCTAssertTrue(rowSource.contains("userMetadata"))
        XCTAssertTrue(rowSource.contains("isUserMetadataHovered = hovering"))
        XCTAssertTrue(rowSource.contains(".opacity(isUserMetadataHovered ? 1 : 0)"))
        XCTAssertTrue(rowSource.contains("Text(timestamp, style: .time)"))
        XCTAssertTrue(rowSource.contains("Button(action: copyMessage)"))
    }

    func testAssistantCopyButtonShowsSubtleShadowOnlyWhileHovered() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let metadataStart = try XCTUnwrap(source.range(of: "private var assistantMetadata"))
        let metadataEnd = try XCTUnwrap(
            source.range(of: "private var copyMessageLabel", range: metadataStart.upperBound..<source.endIndex)
        )
        let metadataSource = source[metadataStart.lowerBound..<metadataEnd.lowerBound]

        XCTAssertTrue(source.contains("@State private var isCopyButtonHovered = false"))
        XCTAssertTrue(metadataSource.contains(
            "color: isCopyButtonHovered ? AppPalette.subtleShadow : Color.clear"
        ))
        XCTAssertTrue(metadataSource.contains(".onHover { isCopyButtonHovered = $0 }"))
        XCTAssertTrue(metadataSource.contains(
            ".animation(.easeOut(duration: 0.12), value: isCopyButtonHovered)"
        ))
    }

    private func makeTool(
        id: String,
        state: SessionToolRunState,
        isError: Bool? = nil,
        approval: AgentHostApprovalRequest? = nil
    ) -> SessionToolRecord {
        SessionToolRecord(
            id: id,
            name: "read",
            summary: #"{"path":"README.md"}"#,
            state: state,
            isError: isError,
            approval: approval
        )
    }

    private func makeAssistantMessage(
        id: String,
        parts: [SessionTranscriptPart]
    ) -> PiChatMessage {
        PiChatMessage(
            message: SessionTranscriptMessage(
                id: id,
                role: .assistant,
                parts: parts,
                timestamp: "2026-08-10T12:00:00.000Z"
            )
        )
    }
}
