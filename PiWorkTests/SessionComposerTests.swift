import AppKit
import ImageIO
import ObjectiveC
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import PiWork

final class SessionComposerTests: XCTestCase {
    func testACPFormStateBuildsTypedContentAndRejectsInvalidNumbers() {
        let request = AgentHostACPElicitationRequest(
            id: "form-one",
            message: "Configure",
            schema: AgentHostACPElicitationSchema(
                properties: [
                    "count": .init(type: .integer, minimum: 1, maximum: 10),
                    "enabled": .init(type: .boolean, defaultValue: .boolean(true)),
                    "mode": .init(
                        type: .string,
                        options: [
                            .init(value: "fast", title: "Fast"),
                            .init(value: "safe", title: "Safe")
                        ]
                    ),
                    "tags": .init(
                        type: .array,
                        defaultValue: .stringArray(["swift"]),
                        options: [.init(value: "swift", title: "Swift")]
                    )
                ],
                required: ["count", "mode"]
            )
        )
        var state = ACPElicitationFormState(request: request)

        XCTAssertNil(state.content)
        state.textValues["count"] = "4"

        XCTAssertEqual(
            state.content,
            [
                "count": .integer(4),
                "enabled": .boolean(true),
                "mode": .string("fast"),
                "tags": .stringArray(["swift"])
            ]
        )
    }

    func testACPFormStateEnforcesStandardStringConstraints() {
        let request = AgentHostACPElicitationRequest(
            id: "form-string",
            message: "Name",
            schema: AgentHostACPElicitationSchema(
                properties: [
                    "name": .init(
                        type: .string,
                        minLength: 3,
                        maxLength: 5,
                        pattern: "^[a-z]+$"
                    )
                ],
                required: ["name"]
            )
        )
        var state = ACPElicitationFormState(request: request)

        XCTAssertNil(state.content)
        state.textValues["name"] = "AB"
        XCTAssertNil(state.content)
        state.textValues["name"] = "swift"
        XCTAssertEqual(state.content, ["name": .string("swift")])
    }

    func testChatPresentsStandardACPElicitationWithoutAPrivateWidgetProtocol() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".sheet(item: elicitationBinding)"))
        XCTAssertTrue(source.contains("private struct ACPElicitationFormView"))
        XCTAssertFalse(source.contains("_piWork/ui_update"))
    }

    func testComposerIncludesGenericACPConfigurationControls() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("genericConfigOptions:"))
        XCTAssertTrue(source.contains("genericModeState:"))
        XCTAssertTrue(source.contains("onSelectConfigOption:"))
        XCTAssertTrue(source.contains("onSelectSessionMode:"))
        XCTAssertTrue(source.contains("agent-config-menu"))
    }

    func testComposerDisplaysACPPlanAndCostUpdates() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("plan: activeRecord?.acpState.plan ?? []"))
        XCTAssertTrue(source.contains("cost: activeRecord?.acpState.cost"))
        XCTAssertTrue(source.contains("struct SessionActivityPanel"))
        XCTAssertTrue(source.contains("session-activity-panel"))
        XCTAssertTrue(source.contains("extensionWidgets: activeRecord?.acpState.extensionWidgets ?? [:]"))
        XCTAssertTrue(source.contains("isExpanded: $isActivityExpanded\n            )\n            .frame(maxWidth: .infinity)"))
        XCTAssertTrue(source.contains("chat.session_cost"))
    }

    @MainActor
    func testCompactActivityPanelVisualLayouts() throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(300), 640] {
                let view = VStack(spacing: 20) {
                    SessionActivityPanel(plan: [], statuses: ["generic": "Ready"], widgets: [:], isExpanded: .constant(false))
                        .frame(maxWidth: .infinity)
                    SessionActivityPanel(plan: [], statuses: [:], widgets: [
                        "tasks": AgentHostExtensionWidget(lines: ["● Todos (1/3)", "├─ ✓ Read project", "├─ ◐ Implement status", "└─ ○ Run tests"]),
                        "workers": AgentHostExtensionWidget(lines: ["● Workers (1/2)", "└─ reviewer · Running"])
                    ], isExpanded: .constant(true))
                    .frame(maxWidth: .infinity)
                    SessionActivityPanel(plan: [], statuses: [:], widgets: [
                        "tasks": AgentHostExtensionWidget(lines: ["● Todos (1/3)", "└─ ○ Run tests"])
                    ], isExpanded: .constant(false))
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                let bitmap = try TestViewRenderer.render(view, size: CGSize(width: width, height: 400))
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "activity-\(scheme)-\(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    func testActivityPanelHidesOnlyExplicitVersionUpdateNotices() {
        func height(_ status: String) -> CGFloat {
            NSHostingView(rootView: SessionActivityPanel(
                plan: [], statuses: ["arbitrary-plugin": status], widgets: [:],
                isExpanded: .constant(false)
            )).fittingSize.height
        }
        XCTAssertEqual(height("bg ⬆ v2.5.0 /bg-update"), 0, accuracy: 1)
        XCTAssertEqual(height("helper ↑ v1.2.3-beta.1 /helper-update"), 0, accuracy: 1)
        for status in ["2 running · ↑ v1.2.3 /helper-update", "Building v1.2.3", "Run /update", "Ready", "更新数据库"] {
            XCTAssertGreaterThan(height(status), 0, status)
        }
    }

    @MainActor
    func testActivityPanelFitsItsContentAndCapsExpandedHeight() {
        func height(lines: [String], expanded: Bool) -> CGFloat {
            let view = SessionActivityPanel(
                plan: [],
                statuses: [:],
                widgets: ["any-plugin": AgentHostExtensionWidget(lines: lines)],
                isExpanded: .constant(expanded)
            )
            .frame(width: 640)
            let hosting = NSHostingView(rootView: view)
            return hosting.fittingSize.height
        }

        XCTAssertEqual(height(lines: [], expanded: false), 0, accuracy: 1)
        XCTAssertEqual(height(lines: ["Ready"], expanded: false), 28, accuracy: 1)
        XCTAssertEqual(height(lines: ["Ready"], expanded: true), 28, accuracy: 1)
        XCTAssertLessThan(height(lines: ["Tasks", "One running"], expanded: true), 110)
        let longContentHeight = height(lines: (1...50).map { "Update \($0)" }, expanded: true)
        XCTAssertGreaterThan(longContentHeight, 200)
        XCTAssertLessThanOrEqual(longContentHeight, 258)
    }

    @MainActor
    func testActivityPanelCapsItsWidth() {
        for expanded in [false, true] {
            let view = SessionActivityPanel(
                plan: [],
                statuses: [:],
                widgets: ["any-plugin": AgentHostExtensionWidget(
                    lines: [String(repeating: "Long plugin update ", count: 12)]
                )],
                isExpanded: .constant(expanded)
            )
            let hosting = NSHostingView(rootView: view)
            let width = hosting.fittingSize.width

            XCTAssertGreaterThan(width, 0)
            XCTAssertLessThanOrEqual(width, expanded ? 440 : 320)
            let narrowHosting = NSHostingView(rootView: view.frame(maxWidth: 260))
            XCTAssertLessThanOrEqual(narrowHosting.fittingSize.width, 260)
        }
    }

    func testToolRowsDisplayStructuredACPContent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("ToolStructuredContentView"))
        XCTAssertTrue(source.contains("ToolDiffBlock"))
        XCTAssertTrue(source.contains("tool-structured-image"))
        XCTAssertTrue(source.contains("chat.tool.terminal_reference"))
    }

    func testApprovalActionsRenderEveryACPOption() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let protocolSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Core/Agent/AgentHostProtocol.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("approval.options"))
        XCTAssertTrue(protocolSource.contains("allow_always"))
        XCTAssertTrue(protocolSource.contains("reject_always"))
    }

    func testSkillUsageProjectionIsCompactDeduplicatedAndNotCopyable() {
        let skill = SessionSkillRecord(id: "skill-one", name: "ego-browser")
        let duplicate = SessionSkillRecord(id: "skill-two", name: "ego-browser")
        let message = PiChatMessage(
            id: "user-one",
            role: .user,
            parts: [
                .skill(skill),
                .text(id: "text-one", text: "使用这个再试试呢"),
                .skill(duplicate)
            ],
            timestamp: nil,
            isStreaming: false
        )

        XCTAssertEqual(message.usedSkills, [skill])
        XCTAssertEqual(message.text, "使用这个再试试呢")
        XCTAssertEqual(message.copyableText, "使用这个再试试呢")
    }

    func testUserSkillUsageRendersAsACompactNonExpandableRow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let userStart = try XCTUnwrap(source.range(of: "case .user:"))
        let assistantStart = try XCTUnwrap(
            source.range(of: "case .assistant:", range: userStart.upperBound..<source.endIndex)
        )
        let userSource = source[userStart.lowerBound..<assistantStart.lowerBound]
        let rowStart = try XCTUnwrap(source.range(of: "private struct SkillUsageRow"))
        let rowEnd = try XCTUnwrap(
            source.range(
                of: "private struct AssistantThinkingView",
                range: rowStart.upperBound..<source.endIndex
            )
        )
        let rowSource = source[rowStart.lowerBound..<rowEnd.lowerBound]

        XCTAssertTrue(userSource.contains("ForEach(message.usedSkills)"))
        XCTAssertTrue(userSource.contains("SkillUsageRow(skill: skill)"))
        XCTAssertTrue(rowSource.contains("L10n.format(\"chat.skill.used\", skill.name)"))
        XCTAssertTrue(rowSource.contains("Image(systemName: \"doc.text\")"))
        XCTAssertFalse(rowSource.contains("Button"))
        XCTAssertFalse(rowSource.contains("chevron"))
    }

    func testHostMessageProjectionPreservesIdentityAndVisibleContent() {
        let source = AgentHostSessionMessage(
            id: "message-one",
            role: .assistant,
            content: [
                .text("完成"),
                .image(mimeType: "image/png", data: nil),
                .toolCall(id: "tool-one", name: "read", argumentsSummary: "README.md")
            ],
            timestamp: "2026-08-09T00:00:00.000Z",
            provider: "openai",
            model: "gpt-test",
            stopReason: nil,
            errorMessage: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil
        )

        let message = PiChatMessage(message: source, isStreaming: true)

        XCTAssertEqual(message.id, "message-one")
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(
            message.text,
            "完成\n\(L10n.format("chat.image_attachment", "image/png"))\n▶ read README.md"
        )
        XCTAssertTrue(message.isStreaming)
    }

    func testTranscriptProjectionPreservesStructuredContentParts() {
        let tool = SessionToolRecord(
            id: "tool-one",
            name: "read",
            summary: #"{"path":"README.md"}"#,
            output: "README contents",
            state: .completed,
            isError: false
        )
        let source = SessionTranscriptMessage(
            id: "assistant-one",
            role: .assistant,
            parts: [
                .text(id: "text-before", text: "**Before**"),
                .tool(tool),
                .text(id: "text-after", text: "After")
            ],
            timestamp: "2026-08-09T00:00:00.000Z"
        )

        let message = PiChatMessage(message: source, isStreaming: true)

        XCTAssertEqual(message.id, source.id)
        XCTAssertEqual(message.parts, source.parts)
        XCTAssertTrue(message.isStreaming)
    }

    func testTranscriptProjectionPreservesTimestampForMessageMetadata() throws {
        let source = SessionTranscriptMessage(
            id: "assistant-one",
            role: .assistant,
            parts: [.text(id: "text-one", text: "Ready")],
            timestamp: "2026-08-09T12:34:56.000Z"
        )

        let message = PiChatMessage(message: source)
        let storedValue = Mirror(reflecting: message)
            .children
            .first { $0.label == "timestamp" }?
            .value
        let timestamp = storedValue.flatMap {
            Mirror(reflecting: $0).children.first?.value as? Date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        XCTAssertEqual(timestamp, try XCTUnwrap(formatter.date(from: source.timestamp)))
    }

    func testHostModelProjectionUsesItsDisplayName() {
        let source = AgentHostModel(
            provider: "openai",
            id: "gpt-test",
            name: "GPT Test",
            contextWindow: 128_000,
            maxTokens: 16_384,
            reasoning: true,
            supportsImages: true
        )

        let model = PiModelOption(model: source)

        XCTAssertEqual(model.id, "openai/gpt-test")
        XCTAssertEqual(model.displayName, "GPT Test")
    }

    func testHostModelProjectionPreservesFastModeCapability() {
        let source = AgentHostModel(
            provider: "openai-codex",
            id: "gpt-5.6-sol",
            name: "GPT-5.6 Sol",
            contextWindow: 272_000,
            maxTokens: 128_000,
            reasoning: true,
            supportsImages: true,
            supportsFastMode: true
        )

        let model = PiModelOption(model: source)
        let capability = Mirror(reflecting: model)
            .children
            .first { $0.label == "supportsFastMode" }?
            .value as? Bool

        XCTAssertEqual(capability, true)
    }

    func testModelSearchMatchesDisplayNameProviderAndIdentifier() {
        let models = [
            PiModelOption(model: makeHostModel(provider: "anthropic", id: "claude-opus-5", name: "Claude Opus 5")),
            PiModelOption(model: makeHostModel(provider: "openai", id: "gpt-5.6-sol", name: "GPT-5.6 Sol")),
            PiModelOption(model: makeHostModel(provider: "google", id: "gemini-3.1-pro", name: "Gemini 3.1 Pro"))
        ]

        XCTAssertEqual(
            SessionComposerState.filteredModels(models, query: "opus").map(\.id),
            ["anthropic/claude-opus-5"]
        )
        XCTAssertEqual(
            SessionComposerState.filteredModels(models, query: "OPENAI").map(\.id),
            ["openai/gpt-5.6-sol"]
        )
        XCTAssertEqual(
            SessionComposerState.filteredModels(models, query: "3.1-pro").map(\.id),
            ["google/gemini-3.1-pro"]
        )
    }

    func testBranchSearchIsCaseInsensitiveAndCapsVisibleRowsAtFive() {
        let branches = [
            "main",
            "feature/session-picker",
            "feature/sidebar",
            "release/1.0",
            "fix/composer",
            "chore/tests"
        ]

        XCTAssertEqual(
            SessionComposerState.filteredGitBranches(branches, query: "FEATURE"),
            ["feature/session-picker", "feature/sidebar"]
        )
        XCTAssertEqual(
            SessionComposerState.visibleGitBranchRowCount(resultCount: branches.count),
            5
        )
        XCTAssertEqual(
            SessionComposerState.visibleGitBranchRowCount(resultCount: 3),
            3
        )
    }

    func testSlashSearchAppearsOnlyAtTheStartOfAWorkDraft() {
        XCTAssertEqual(
            SessionComposerState.slashQuery(in: "/ego", mode: .work),
            "ego"
        )
        XCTAssertEqual(
            SessionComposerState.slashQuery(in: "/ego 看一下 x.com", mode: .work),
            "ego"
        )
        XCTAssertNil(SessionComposerState.slashQuery(in: "请用 /ego", mode: .work))
        XCTAssertNil(SessionComposerState.slashQuery(in: "/ego", mode: .chat))
    }

    func testSlashSearchMatchesCommandNameDescriptionAndKind() {
        let commands = [
            AgentHostSlashCommand(
                name: "skill:ego-browser",
                description: "Browse and interact with websites",
                source: .skill
            ),
            AgentHostSlashCommand(
                name: "review",
                description: "Inspect the current changes",
                source: .extensionCommand
            )
        ]

        XCTAssertEqual(
            SessionComposerState.filteredSlashCommands(commands, query: "ego").map(\.name),
            ["skill:ego-browser"]
        )
        XCTAssertEqual(
            SessionComposerState.filteredSlashCommands(commands, query: "inspect").map(\.name),
            ["review"]
        )
        XCTAssertEqual(
            SessionComposerState.filteredSlashCommands(commands, query: "skill").map(\.name),
            ["skill:ego-browser"]
        )
    }

    func testSelectingSlashCommandPreservesTheMessageAndBuildsAnInvokablePrompt() {
        let skill = AgentHostSlashCommand(
            name: "skill:ego-browser",
            description: "Browse and interact with websites",
            source: .skill
        )

        let remainingDraft = SessionComposerState.draftAfterSelectingSlashCommand(
            from: "/ego 看一下 x.com"
        )

        XCTAssertEqual(skill.displayName, "Ego Browser")
        XCTAssertEqual(remainingDraft, "看一下 x.com")
        XCTAssertEqual(
            SessionComposerState.submissionText(
                draft: remainingDraft,
                selectedCommand: skill
            ),
            "/skill:ego-browser 看一下 x.com"
        )
        XCTAssertEqual(
            SessionComposerState.submissionText(draft: "", selectedCommand: skill),
            "/skill:ego-browser"
        )
    }

    func testSkillAndExtensionCommandsUseDifferentIcons() {
        XCTAssertEqual(
            AgentHostSlashCommandSource.skill.composerIcon,
            "doc.text"
        )
        XCTAssertNotEqual(
            AgentHostSlashCommandSource.skill.composerIcon,
            AgentHostSlashCommandSource.extensionCommand.composerIcon
        )
    }

    func testSelectedSlashCommandOnlyMovesFirstEditorLinePastItsToken() {
        let font = NSFont.systemFont(ofSize: 15)
        let textStorage = NSTextStorage(
            string: "first\nsecond\nthird",
            attributes: [.font: font]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 320, height: 120))
        textContainer.lineFragmentPadding = 0
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let lineHeight = layoutManager.defaultLineHeight(for: font)
        textContainer.exclusionPaths = [
            NSBezierPath(
                rect: SessionComposerState.slashTokenExclusionRect(
                    tokenWidth: 120,
                    lineHeight: lineHeight
                )
            )
        ]
        layoutManager.ensureLayout(for: textContainer)

        var lineOrigins: [CGFloat] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        ) { _, usedRect, _, _, _ in
            lineOrigins.append(usedRect.minX)
        }

        XCTAssertEqual(lineOrigins.count, 3)
        XCTAssertGreaterThan(lineOrigins[0], 120)
        XCTAssertEqual(lineOrigins[1], 0, accuracy: 0.5)
        XCTAssertEqual(lineOrigins[2], 0, accuracy: 0.5)
    }

    func testPromptHistoryWalksBackwardThenRestoresTheUnsentDraft() {
        var navigation = SessionComposerPromptHistoryNavigation()
        let prompts = ["first prompt", "second prompt", "third prompt"]

        XCTAssertEqual(
            navigation.previous(in: prompts, currentDraft: "unfinished draft"),
            "third prompt"
        )
        XCTAssertEqual(
            navigation.previous(in: prompts, currentDraft: "third prompt"),
            "second prompt"
        )
        XCTAssertEqual(
            navigation.previous(in: prompts, currentDraft: "second prompt"),
            "first prompt"
        )
        XCTAssertEqual(
            navigation.previous(in: prompts, currentDraft: "first prompt"),
            "first prompt"
        )
        XCTAssertEqual(navigation.next(in: prompts), "second prompt")
        XCTAssertEqual(navigation.next(in: prompts), "third prompt")
        XCTAssertEqual(navigation.next(in: prompts), "unfinished draft")
        XCTAssertNil(navigation.next(in: prompts))
    }

    func testPromptHistoryArrowKeysOnlyActivateAtLogicalEditorEdges() {
        let text = "first line\nsecond line"

        XCTAssertTrue(
            SessionComposerState.shouldNavigatePromptHistory(
                .previous,
                in: text,
                selection: NSRange(location: 5, length: 0)
            )
        )
        XCTAssertFalse(
            SessionComposerState.shouldNavigatePromptHistory(
                .previous,
                in: text,
                selection: NSRange(location: 11, length: 0)
            )
        )
        XCTAssertFalse(
            SessionComposerState.shouldNavigatePromptHistory(
                .next,
                in: text,
                selection: NSRange(location: 5, length: 0)
            )
        )
        XCTAssertTrue(
            SessionComposerState.shouldNavigatePromptHistory(
                .next,
                in: text,
                selection: NSRange(location: 11, length: 0)
            )
        )
        XCTAssertFalse(
            SessionComposerState.shouldNavigatePromptHistory(
                .next,
                in: text,
                selection: NSRange(location: 11, length: 2)
            )
        )
        XCTAssertFalse(
            SessionComposerState.shouldNavigatePromptHistory(
                .previous,
                in: text,
                selection: NSRange(location: 5, length: 0),
                hasMarkedText: true
            )
        )
    }

    func testPromptHistoryRestoresAnInvokableSlashCommandAsASelectedToken() {
        let command = AgentHostSlashCommand(
            name: "skill:ego-browser",
            description: "Browse websites",
            source: .skill
        )

        let recalled = SessionComposerState.recalledPrompt(
            "/skill:ego-browser 看一下 x.com",
            commands: [command]
        )

        XCTAssertEqual(recalled.selectedCommand, command)
        XCTAssertEqual(recalled.draft, "看一下 x.com")
        XCTAssertEqual(
            SessionComposerState.recalledPrompt("普通问题", commands: [command]),
            SessionComposerRecalledPrompt(draft: "普通问题", selectedCommand: nil)
        )
    }

    func testComposerWiresArrowKeysToSessionPromptHistory() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("promptHistoryNavigation.previous"))
        XCTAssertTrue(source.contains("promptHistoryNavigation.next"))
        XCTAssertTrue(source.contains("shouldNavigatePromptHistory"))
        XCTAssertTrue(source.contains(".recallPreviousPrompt"))
        XCTAssertTrue(source.contains(".recallNextPrompt"))
    }

    func testWorkComposerWiresSlashMenuKeyboardNavigationAndSelectedToken() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("slashCommandPanel"))
        XCTAssertTrue(source.contains("slash-command-menu"))
        XCTAssertTrue(source.contains("selectedSlashCommandToken"))
        XCTAssertTrue(source.contains("handleEditorCommand"))
        XCTAssertTrue(source.contains("command.source.composerIcon"))
        XCTAssertTrue(source.contains("await sessionStore.slashCommands"))
    }

    func testModelPickerShowsAtMostFiveRowsBeforeScrolling() {
        XCTAssertEqual(SessionComposerState.visibleModelRowCount(resultCount: 3), 3)
        XCTAssertEqual(SessionComposerState.visibleModelRowCount(resultCount: 5), 5)
        XCTAssertEqual(SessionComposerState.visibleModelRowCount(resultCount: 12), 5)
    }

    func testContextUsagePresentationMatchesCompactHoverDetails() {
        let presentation = ContextUsagePresentation(
            usage: AgentHostContextUsage(
                tokens: 194_000,
                contextWindow: 258_000,
                percent: 75.2
            )
        )

        XCTAssertEqual(presentation.progress, 0.752, accuracy: 0.001)
        XCTAssertEqual(presentation.percentText, L10n.format("context.percent_used", 75))
        XCTAssertEqual(
            presentation.detailText,
            L10n.format("context.used_total", "194k", "258k")
        )
    }

    func testContextUsagePresentationHandlesPostCompactionUnknownState() {
        let presentation = ContextUsagePresentation(
            usage: AgentHostContextUsage(
                tokens: nil,
                contextWindow: 128_000,
                percent: nil
            )
        )

        XCTAssertEqual(presentation.progress, 0)
        XCTAssertEqual(presentation.percentText, L10n.string("context.recalculating"))
        XCTAssertEqual(presentation.detailText, L10n.format("context.total", "128k"))
    }

    func testModelProvidersUseLobeHubIconAssetsAndThinkingLevelsExposeTitles() {
        let anthropic = PiModelOption(
            model: makeHostModel(provider: "anthropic", id: "claude-opus-5", name: "Claude Opus 5")
        )
        let openAI = PiModelOption(
            model: makeHostModel(provider: "openai", id: "gpt-5.6-sol", name: "GPT-5.6 Sol")
        )
        let routedClaude = PiModelOption(
            model: makeHostModel(provider: "openai", id: "claude-opus-5", name: "Claude Opus 5")
        )
        let gemini = PiModelOption(
            model: makeHostModel(provider: "google", id: "gemini-3.1-pro", name: "Gemini 3.1 Pro")
        )
        let kimi = PiModelOption(
            model: makeHostModel(provider: "moonshot", id: "kimi-k2.5", name: "Kimi K2.5")
        )
        let grok = PiModelOption(
            model: makeHostModel(provider: "xai", id: "grok-4", name: "Grok 4")
        )
        let deepSeek = PiModelOption(
            model: makeHostModel(provider: "deepseek", id: "deepseek-v3", name: "DeepSeek V3")
        )
        let unknown = PiModelOption(
            model: makeHostModel(provider: "custom", id: "private-model", name: "Private Model")
        )

        XCTAssertEqual(anthropic.providerIconAssetName, "ModelIconClaude")
        XCTAssertEqual(openAI.providerIconAssetName, "ModelIconOpenAI")
        XCTAssertEqual(routedClaude.providerIconAssetName, "ModelIconClaude")
        XCTAssertEqual(gemini.providerIconAssetName, "ModelIconGemini")
        XCTAssertEqual(kimi.providerIconAssetName, "ModelIconKimi")
        XCTAssertEqual(grok.providerIconAssetName, "ModelIconGrok")
        XCTAssertEqual(deepSeek.providerIconAssetName, "ModelIconDeepSeek")
        XCTAssertEqual(unknown.providerIconAssetName, "ModelIconLobeHub")
        XCTAssertEqual(
            AgentHostThinkingLevel.xhigh.composerTitle,
            L10n.string("settings.thinking.xhigh")
        )
        XCTAssertEqual(
            AgentHostThinkingLevel.max.composerTitle,
            L10n.string("settings.thinking.max")
        )
    }

    func testCatalogModelFamiliesUseOfficialBrandAssets() {
        let expectations = [
            ("openrouter", "qwen/qwen3-coder", "Qwen3 Coder", "ModelIconQwen"),
            ("amazon-bedrock", "meta.llama4-maverick", "Llama 4 Maverick", "ModelIconMeta"),
            ("openrouter", "mistralai/devstral-small", "Devstral Small", "ModelIconMistral"),
            ("vercel-ai-gateway", "minimax/minimax-m2", "MiniMax M2", "ModelIconMiniMax"),
            ("openrouter", "z-ai/glm-5", "GLM 5", "ModelIconZAI"),
            ("openrouter", "xiaomi/mimo-v2-flash", "MiMo V2 Flash", "ModelIconXiaomiMiMo"),
            ("openrouter", "nvidia/nemotron-3-nano", "Nemotron 3 Nano", "ModelIconNVIDIA"),
            ("amazon-bedrock", "amazon.nova-pro", "Amazon Nova Pro", "ModelIconNova"),
            ("google", "gemma-3-27b", "Gemma 3 27B", "ModelIconGemma"),
            ("cohere", "command-r-plus", "Command R+", "ModelIconCohere"),
            ("openrouter", "stepfun/step-3.5-flash", "Step 3.5 Flash", "ModelIconStepFun"),
            ("azure", "phi-4", "Phi 4", "ModelIconMicrosoft"),
            ("cloudflare-ai-gateway", "o3-mini", "o3-mini", "ModelIconOpenAI")
        ]

        for (provider, id, name, assetName) in expectations {
            let model = PiModelOption(
                model: makeHostModel(provider: provider, id: id, name: name)
            )
            XCTAssertEqual(model.providerIconAssetName, assetName, "Unexpected icon for \(name)")
        }
    }

    func testThinkingSliderMapsItsPositionToAvailableModelLevels() {
        let levels: [AgentHostThinkingLevel] = [.off, .minimal, .low, .medium, .high]

        XCTAssertEqual(
            SessionComposerState.thinkingLevel(forSliderValue: 0, availableLevels: levels),
            .off
        )
        XCTAssertEqual(
            SessionComposerState.thinkingLevel(forSliderValue: 2.2, availableLevels: levels),
            .low
        )
        XCTAssertEqual(
            SessionComposerState.thinkingLevel(forSliderValue: 99, availableLevels: levels),
            .high
        )
        XCTAssertNil(
            SessionComposerState.thinkingLevel(forSliderValue: 0, availableLevels: [])
        )
    }

    func testEmptyPersistedMessageIsHiddenUnlessItIsStreaming() {
        let source = AgentHostSessionMessage(
            id: "empty-assistant",
            role: .assistant,
            content: [],
            timestamp: "2026-08-09T00:00:00.000Z",
            provider: nil,
            model: nil,
            stopReason: nil,
            errorMessage: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil
        )

        XCTAssertFalse(PiChatMessage(message: source).isVisible)
        XCTAssertTrue(PiChatMessage(message: source, isStreaming: true).isVisible)
    }

    func testPrimaryActionReflectsDraftAndExecutionState() {
        XCTAssertEqual(SessionComposerState.primaryAction(draft: "", isExecuting: false), .none)
        XCTAssertEqual(SessionComposerState.primaryAction(draft: "  \n", isExecuting: false), .none)
        XCTAssertEqual(SessionComposerState.primaryAction(draft: "整理项目", isExecuting: false), .send)
        XCTAssertEqual(
            SessionComposerState.primaryAction(
                draft: "",
                hasAttachments: true,
                isExecuting: false
            ),
            .send
        )
        XCTAssertEqual(SessionComposerState.primaryAction(draft: "", isExecuting: true), .stop)
        XCTAssertEqual(SessionComposerState.primaryAction(draft: "后续消息", isExecuting: true), .stop)
        XCTAssertEqual(
            SessionComposerState.primaryAction(
                draft: "",
                hasAttachments: true,
                isExecuting: true
            ),
            .stop
        )
    }

    func testImagePasteboardReaderPrefersImageDataOverText() throws {
        let pasteboard = NSPasteboard(name: .init("pi-work-image-paste-test-\(UUID())"))
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }

        let imageData = try makeComposerTestImageData(width: 8, height: 8)
        let item = NSPasteboardItem()
        item.setString("https://example.com/image.png", forType: .string)
        item.setData(imageData, forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertEqual(
            ComposerImagePasteboard.sources(from: pasteboard),
            [ComposerImageSource(data: imageData)]
        )
    }

    func testImagePasteboardReaderIgnoresTextOnlyPasteboard() {
        let pasteboard = NSPasteboard(name: .init("pi-work-text-paste-test-\(UUID())"))
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        pasteboard.setString("普通文本", forType: .string)

        XCTAssertTrue(ComposerImagePasteboard.sources(from: pasteboard).isEmpty)
    }

    func testImagePasteboardReaderLoadsFinderImageFiles() throws {
        let imageData = try makeComposerTestImageData(width: 8, height: 8)
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-paste-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try imageData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let pasteboard = NSPasteboard(name: .init("pi-work-file-paste-test-\(UUID())"))
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        item.setString(imageURL.absoluteString, forType: .fileURL)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertEqual(
            ComposerImagePasteboard.sources(from: pasteboard),
            [ComposerImageSource(data: imageData)]
        )
    }

    func testImageProcessorNormalizesDeduplicatesAndResizesImages() throws {
        let imageData = try makeComposerTestImageData(width: 2_200, height: 1_100)

        let attachments = try ComposerImageProcessor.process([
            ComposerImageSource(data: imageData),
            ComposerImageSource(data: imageData)
        ])

        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertLessThanOrEqual(max(attachment.pixelWidth, attachment.pixelHeight), 2_000)
        XCTAssertNotNil(CGImageSourceCreateWithData(attachment.data as CFData, nil))
    }

    func testImageProcessorRejectsMoreThanFiveDistinctImages() throws {
        let sources = try (0..<6).map { index in
            ComposerImageSource(
                data: try makeComposerTestImageData(
                    width: 8,
                    height: 8,
                    red: CGFloat(index) / 6
                )
            )
        }

        XCTAssertThrowsError(try ComposerImageProcessor.process(sources)) { error in
            XCTAssertEqual(error as? ComposerImageAttachmentError, .tooManyImages)
        }
    }

    @MainActor
    func testComposerResignsFocusWhenClickingOutsideTheSurface() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        let host = NSView(frame: window.contentView!.bounds)
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        let surface = ComposerSurfaceView(frame: NSRect(x: 40, y: 40, width: 200, height: 80))
        host.addSubview(surface)

        XCTAssertTrue(surface.containsClick(in: window, location: NSPoint(x: 100, y: 60)))
        XCTAssertFalse(surface.containsClick(in: window, location: NSPoint(x: 10, y: 10)))

        let textView = ComposerTextView(frame: NSRect(x: 50, y: 50, width: 120, height: 40))
        host.addSubview(textView)
        window.makeFirstResponder(textView)
        XCTAssertTrue(window.firstResponder === textView)

        let outside = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        ComposerFocusDismissal.resignComposerFocusIfNeeded(for: outside)
        XCTAssertFalse(window.firstResponder is ComposerTextView)

        window.makeFirstResponder(textView)
        let inside = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 60),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        )!
        ComposerFocusDismissal.resignComposerFocusIfNeeded(for: inside)
        XCTAssertTrue(window.firstResponder === textView)
    }

    func testSessionComposerMarksSurfaceForOutsideFocusDismissal() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chatSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let attachmentSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/ComposerImageAttachment.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(chatSource.contains("ComposerSurfaceMarker()"))
        XCTAssertTrue(attachmentSource.contains("enum ComposerFocusDismissal"))
        XCTAssertTrue(attachmentSource.contains("makeFirstResponder(nil)"))
    }

    func testComposerTextViewOffersPasteboardToAttachmentHandler() {

        let pasteboard = NSPasteboard(name: .init("pi-work-editor-paste-test-\(UUID())"))
        let textView = ComposerTextView()
        var receivedPasteboardName: NSPasteboard.Name?
        textView.onPasteboard = { receivedPasteboard in
            receivedPasteboardName = receivedPasteboard.name
            return true
        }

        XCTAssertTrue(textView.consumePasteboard(pasteboard))
        XCTAssertEqual(receivedPasteboardName, pasteboard.name)
    }

    func testComposerTextViewOverridesPasteCommandValidation() throws {
        let baseMethod = try XCTUnwrap(
            class_getInstanceMethod(
                NSTextView.self,
                #selector(NSUserInterfaceValidations.validateUserInterfaceItem(_:))
            )
        )
        let composerMethod = try XCTUnwrap(
            class_getInstanceMethod(
                ComposerTextView.self,
                #selector(NSUserInterfaceValidations.validateUserInterfaceItem(_:))
            )
        )

        XCTAssertNotEqual(
            method_getImplementation(composerMethod),
            method_getImplementation(baseMethod)
        )
    }

    func testAttachmentSendAvailabilityRequiresReadyVisionModel() {
        XCTAssertTrue(
            SessionComposerState.canSend(
                baseCanSend: true,
                hasAttachments: false,
                isProcessingAttachments: false,
                selectedModelSupportsImages: false
            )
        )
        XCTAssertTrue(
            SessionComposerState.canSend(
                baseCanSend: true,
                hasAttachments: true,
                isProcessingAttachments: false,
                selectedModelSupportsImages: true
            )
        )
        XCTAssertFalse(
            SessionComposerState.canSend(
                baseCanSend: true,
                hasAttachments: true,
                isProcessingAttachments: false,
                selectedModelSupportsImages: false
            )
        )
        XCTAssertFalse(
            SessionComposerState.canSend(
                baseCanSend: true,
                hasAttachments: true,
                isProcessingAttachments: true,
                selectedModelSupportsImages: true
            )
        )
    }

    func testPromptHistoryExcludesImagePlaceholdersAndImageOnlyPrompts() {
        let imageOnly = PiChatMessage(
            id: "image-only",
            role: .user,
            parts: [.image(id: "image-one", mimeType: "image/png", data: nil)],
            timestamp: nil,
            isStreaming: false
        )
        let mixed = PiChatMessage(
            id: "mixed",
            role: .user,
            parts: [
                .text(id: "text-one", text: "分析这张图"),
                .image(id: "image-two", mimeType: "image/png", data: nil)
            ],
            timestamp: nil,
            isStreaming: false
        )

        XCTAssertEqual(SessionComposerState.promptHistory(in: [imageOnly, mixed]), ["分析这张图"])
    }

    func testConversationSurfaceConnectsImagePastePreviewAndSend() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("ComposerImagePasteboard.sources(from: pasteboard)"))
        XCTAssertTrue(source.contains("private var imageAttachmentStrip"))
        XCTAssertTrue(source.contains("selectedModelSupportsImages"))
        XCTAssertTrue(source.contains("images: promptImages"))
        XCTAssertTrue(source.contains("let textView = ComposerTextView"))
    }

    func testImageThumbnailOpensDismissiblePreview() throws {
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
            source.contains(
                "@State private var previewedImageAttachment: ComposerImageAttachment?"
            )
        )
        XCTAssertTrue(source.contains("previewedImageAttachment = attachment"))
        XCTAssertTrue(source.contains(".sheet(item: $previewedImageAttachment)"))
        XCTAssertTrue(source.contains("private struct ComposerImagePreview: View"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(
            source.contains(
                ".accessibilityIdentifier(\"image-attachment-preview\")"
            )
        )
    }

    func testSentUserImagesRenderAsClickableThumbnailsBelowText() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let presentationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/ChatPresentation.swift"
            ),
            encoding: .utf8
        )
        let viewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(presentationSource.contains("var imageAttachments:"))
        XCTAssertTrue(presentationSource.contains("data == nil"))
        XCTAssertTrue(viewSource.contains("ForEach(message.imageAttachments)"))
        XCTAssertTrue(viewSource.contains("previewedMessageImage = image"))
        XCTAssertTrue(viewSource.contains("ComposerImagePreview(data: image.data)"))
    }

    func testOnlyWorkSessionsExposeProjectSelection() {
        XCTAssertFalse(SidebarTab.chat.showsProjectSelection)
        XCTAssertTrue(SidebarTab.work.showsProjectSelection)
    }

    func testWorkAccessModesHaveExplicitUserFacingMeaning() {
        XCTAssertEqual(AgentHostAccessMode.readOnly.composerTitle, L10n.string("access.read_only.title"))
        XCTAssertEqual(AgentHostAccessMode.ask.composerTitle, L10n.string("access.ask.title"))
        XCTAssertEqual(AgentHostAccessMode.full.composerTitle, L10n.string("access.full.title"))
        XCTAssertEqual(
            AgentHostAccessMode.full.composerDescription,
            L10n.string("access.full.description")
        )
    }

    func testWorkAccessModePickerOnlyOffersAskAndFullAccess() {
        XCTAssertEqual(AgentHostAccessMode.workChoices, [.ask, .full])
    }

    func testConversationSurfaceExposesAccessAndApprovalControls() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("session-access-mode"))
        XCTAssertTrue(source.contains("InlineApprovalActions"))
        XCTAssertTrue(source.contains("approval.options"))
        XCTAssertTrue(source.contains("approval-\\(option.kind.rawValue)"))
    }

    func testConversationDoesNotReserveSpaceForFloatingSidebarToggle() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Color.clear.frame(height: 32)"))
        XCTAssertFalse(source.contains("Color.clear.frame(height: 64)"))
    }

    func testComposerUsesCompactVerticalInsets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let bodyStart = try XCTUnwrap(source.range(of: "var body: some View"))
        let bodyEnd = try XCTUnwrap(
            source.range(of: ".overlay(alignment: .top)", range: bodyStart.upperBound..<source.endIndex)
        )
        let editorStart = try XCTUnwrap(source.range(of: "private var editor: some View"))
        let editorEnd = try XCTUnwrap(
            source.range(
                of: "private var imageAttachmentStrip",
                range: editorStart.upperBound..<source.endIndex
            )
        )
        let bodySource = source[bodyStart.lowerBound..<bodyEnd.lowerBound]
        let editorSource = source[editorStart.lowerBound..<editorEnd.lowerBound]

        XCTAssertTrue(bodySource.contains(".padding(.bottom, 16)"))
        XCTAssertTrue(editorSource.contains(".padding(.top, 10)"))
        XCTAssertTrue(editorSource.contains(".padding(.bottom, 8)"))
    }

    func testComposerDoesNotGrowForInputMethodCandidatePanel() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let editorSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(editorSource.contains("candidatePanelClearance"))
        XCTAssertFalse(editorSource.contains("Color.clear\n                .frame(height: isInputMethodComposing"))
    }

    func testComposerHidesPlaceholderWhileInputMethodIsComposing() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "if draft.isEmpty, selectedSlashCommand == nil, !isInputMethodComposing"
        ))
    }

    func testSuggestionCardsUseCompactLandscapeHeight() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let cardStart = try XCTUnwrap(source.range(of: "private struct SessionSuggestionCard"))
        let cardEnd = try XCTUnwrap(
            source.range(of: "private struct GitBranchIcon", range: cardStart.upperBound..<source.endIndex)
        )
        let cardSource = source[cardStart.lowerBound..<cardEnd.lowerBound]

        XCTAssertTrue(cardSource.contains("Spacer(minLength: 0)"))
        XCTAssertTrue(cardSource.contains(".frame(height: 104)"))
        XCTAssertTrue(cardSource.contains(
            ".frame(maxWidth: .infinity, alignment: .leading)"
        ))
        XCTAssertFalse(cardSource.contains("minHeight: 112"))
    }

    func testExploreSuggestionUsesResolvableSystemIcon() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let defaultsStart = try XCTUnwrap(source.range(of: "static var defaults"))
        let defaultsSource = String(source[defaultsStart.lowerBound...])
        let iconPattern = #"SessionSuggestion\(\s*icon: \"([^\"]+)\""#
        let iconRegex = try NSRegularExpression(pattern: iconPattern)
        let searchRange = NSRange(defaultsSource.startIndex..., in: defaultsSource)
        let match = try XCTUnwrap(iconRegex.firstMatch(in: defaultsSource, range: searchRange))
        let iconRange = try XCTUnwrap(Range(match.range(at: 1), in: defaultsSource))
        let iconName = String(defaultsSource[iconRange])

        XCTAssertNotNil(
            NSImage(systemSymbolName: iconName, accessibilityDescription: nil),
            "The explore suggestion icon '\(iconName)' must resolve on macOS"
        )
    }

    func testTranscriptTopFadeStartsOpaqueAndEndsTransparent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let bodyStart = try XCTUnwrap(source.range(of: "var body: some View"))
        let transcriptStart = try XCTUnwrap(
            source.range(
                of: "private func transcript(",
                range: bodyStart.upperBound..<source.endIndex
            )
        )
        let transcriptEnd = try XCTUnwrap(
            source.range(of: "private var emptySession", range: transcriptStart.upperBound..<source.endIndex)
        )
        let bodySource = source[bodyStart.lowerBound..<transcriptStart.lowerBound]
        let transcriptSource = source[transcriptStart.lowerBound..<transcriptEnd.lowerBound]

        XCTAssertTrue(bodySource.contains(".overlay(alignment: .top)"))
        XCTAssertTrue(bodySource.contains("AppPalette.transcriptTopFadeSurface"))
        XCTAssertTrue(bodySource.contains("LinearGradient("))
        XCTAssertTrue(bodySource.contains("colors: [.black, .clear]"))
        XCTAssertEqual(bodySource.components(separatedBy: ".frame(height: 32)").count - 1, 2)
        XCTAssertFalse(bodySource.contains(".frame(height: 64)"))
        XCTAssertTrue(bodySource.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertFalse(bodySource.contains(".offset(y: -64)"))
        XCTAssertFalse(bodySource.contains(".fill(.ultraThinMaterial)"))
        XCTAssertFalse(bodySource.contains(".opacity(0.32)"))
        XCTAssertTrue(bodySource.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(transcriptSource.contains("AppPalette.transcriptTopFadeSurface"))
    }

    func testOpeningWorkSessionShowsTranscriptLoadingMaskUntilHistoryLoads() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chatSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/App/Root/ContentView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(chatSource.contains("if isSessionTransitioning {"))
        XCTAssertTrue(chatSource.contains("SessionTranscriptLoadingMask()"))
        XCTAssertTrue(chatSource.contains("accessibilityReduceMotion"))
        XCTAssertTrue(chatSource.contains("repeatForever(autoreverses: false)"))
        XCTAssertTrue(contentSource.contains("sessionOpeningState.begin("))
        XCTAssertTrue(contentSource.contains("await Task.yield()"))
        XCTAssertTrue(contentSource.contains("isLoadingSession: isOpeningSelectedSession"))
    }

    func testCachedSessionSelectionBypassesLoadingState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/App/Root/ContentView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("selectCachedSessionIfAvailable("))
        XCTAssertTrue(source.contains("guard !selectCachedSessionIfAvailable("))
    }

    func testSessionSwitchKeepsChatSurfaceIdentityStable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/App/Root/ContentView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(".id(activeSessionIdentity)"))
    }

    func testUncachedSessionLoadingUsesOverlayMask() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("SessionTranscriptLoadingMask()"))
        XCTAssertTrue(source.contains("if isSessionTransitioning {\n                    SessionTranscriptLoadingMask()"))
    }

    func testSessionLoadingMaskIsOpaqueAndDoesNotCreateAnotherScrollView() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let mask = try XCTUnwrap(
            source.components(separatedBy: "private struct SessionTranscriptLoadingMask").last?
                .components(separatedBy: "private struct SkeletonLine").first
        )

        XCTAssertTrue(mask.contains("AppPalette.windowGradient"))
        XCTAssertFalse(mask.contains("windowBackgroundColor).opacity"))
        XCTAssertFalse(mask.contains("ScrollView {"))
    }

    func testSessionLoadingMaskCoversTheFullSizeTitlebarArea() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let mask = try XCTUnwrap(
            source.components(separatedBy: "private struct SessionTranscriptLoadingMask").last?
                .components(separatedBy: "private struct SessionComposerLoadingMask").first
        )

        XCTAssertTrue(mask.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        XCTAssertTrue(mask.contains(".ignoresSafeArea(.container, edges: .top)"))
    }

    func testSessionTransitionHidesUnderlyingTranscriptOverflow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let chatView = try XCTUnwrap(
            source.components(separatedBy: "struct ChatView: View {").last
        )
        let body = try XCTUnwrap(
            chatView.components(separatedBy: "var body: some View").dropFirst().first?
                .components(separatedBy: "private func transcript(").first
        )

        XCTAssertTrue(body.contains(".opacity(isSessionTransitioning ? 0 : 1)"))
        XCTAssertTrue(body.contains(".animation(nil, value: isSessionTransitioning)"))
    }

    func testSessionTransitionBlocksUnderlyingTranscriptAndComposerInteraction() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var isSessionTransitioning: Bool"))
        XCTAssertTrue(source.contains(".allowsHitTesting(!isSessionTransitioning)"))
        XCTAssertTrue(source.contains(".accessibilityHidden(isSessionTransitioning)"))
        XCTAssertTrue(source.contains(".disabled(isSessionTransitioning)"))
        XCTAssertTrue(source.contains("SessionComposerLoadingMask()"))
    }

    func testSessionTransitionStartsWhenPresentationIdentityChanges() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let transition = try XCTUnwrap(
            source.components(separatedBy: "private var isSessionTransitioning: Bool {").last?
                .components(separatedBy: "\n    }").first
        )

        XCTAssertTrue(source.contains("@State private var readySessionPresentationID: String?"))
        XCTAssertTrue(transition.contains("readySessionPresentationID != sessionPresentationID"))
    }

    func testTranscriptUsesStableLayoutForBoundedMessageWindow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        let transcriptStart = try XCTUnwrap(source.range(of: "private func transcript"))
        let transcriptEnd = try XCTUnwrap(
            source.range(
                of: "private func scrollToTranscriptTail",
                range: transcriptStart.upperBound..<source.endIndex
            )
        )
        let transcriptSource = source[transcriptStart.lowerBound..<transcriptEnd.lowerBound]
        XCTAssertTrue(transcriptSource.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertFalse(transcriptSource.contains("LazyVStack(alignment: .leading, spacing: 12)"))
    }

    func testChatViewSlicesTranscriptBeforeMappingChatMessages() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let messages = try XCTUnwrap(
            source.components(separatedBy: "private var messagePresentation:").last?
                .components(separatedBy: "private func transcriptScrollToken").first
        )

        XCTAssertTrue(messages.contains("TranscriptProjection.recentMessages("))
        XCTAssertFalse(source.contains("let visibleMessages = record.transcript.map"))
    }

    func testSessionPresentationRevealsTheInitialBatchBeforeExpandingTheWindow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let task = try XCTUnwrap(
            source.components(separatedBy: ".task(id: sessionPresentationID) {").last?
                .components(separatedBy: "\n        }").first
        )
        let initialWindow = try XCTUnwrap(
            task.range(of: "presentedMessageLimit = SessionPresentationBatch.initialCount")
        )
        let finalScroll = try XCTUnwrap(
            task.range(
                of: "transcriptScrollRequest &+= 1",
                range: initialWindow.upperBound..<task.endIndex
            )
        )
        let reveal = try XCTUnwrap(
            task.range(
                of: "isPreparingSessionPresentation = false",
                range: finalScroll.upperBound..<task.endIndex
            )
        )
        let progressiveExpansion = try XCTUnwrap(
            task.range(
                of: "while presentedMessageLimit < transcriptMessageLimit",
                range: reveal.upperBound..<task.endIndex
            )
        )

        XCTAssertLessThan(finalScroll.lowerBound, reveal.lowerBound)
        XCTAssertLessThan(reveal.lowerBound, progressiveExpansion.lowerBound)
    }

    func testTranscriptAutomaticallyLoadsEarlierMessagesNearTop() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("onReachTop:"))
        XCTAssertTrue(source.contains("loadEarlierMessages("))
        XCTAssertTrue(source.contains("try await sessionStore.loadEarlierMessages("))
        XCTAssertTrue(source.contains("record.hasEarlierMessages"))
        XCTAssertTrue(source.contains("proxy.scrollTo(anchorID, anchor: .top)"))
        XCTAssertFalse(source.contains("accessibilityIdentifier(\"load-earlier-messages\")"))
    }

    func testAccessModePickerUsesSameRoundedInteractionAsModelPicker() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let menuStart = try XCTUnwrap(source.range(of: "private func accessModeMenu"))
        let menuEnd = try XCTUnwrap(
            source.range(of: "@ViewBuilder", range: menuStart.upperBound..<source.endIndex)
        )
        let menuSource = source[menuStart.lowerBound..<menuEnd.lowerBound]

        XCTAssertTrue(source.contains("@State private var isAccessPickerPresented = false"))
        XCTAssertTrue(menuSource.contains("isAccessPickerPresented.toggle()"))
        XCTAssertTrue(menuSource.contains("RoundedInteractionButtonStyle("))
        XCTAssertTrue(menuSource.contains("isSelected: isAccessPickerPresented"))
        XCTAssertTrue(menuSource.contains(
            ".popover(isPresented: $isAccessPickerPresented, arrowEdge: .top)"
        ))
        XCTAssertTrue(menuSource.contains("onSelectAccessMode(accessMode)"))
        XCTAssertTrue(menuSource.contains("isAccessPickerPresented = false"))
        XCTAssertFalse(menuSource.contains("Menu {"))
        XCTAssertFalse(source.contains("MenuHoverTrackingView"))
        XCTAssertFalse(source.contains("MenuHoverTrackingNSView"))
    }

    func testAccessModePickerUsesCompactMenuRows() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let pickerStart = try XCTUnwrap(source.range(of: "private func accessModePickerContent"))
        let pickerEnd = try XCTUnwrap(
            source.range(of: "@ViewBuilder", range: pickerStart.upperBound..<source.endIndex)
        )
        let pickerSource = source[pickerStart.lowerBound..<pickerEnd.lowerBound]

        XCTAssertTrue(pickerSource.contains(".frame(width: 184)"))
        XCTAssertTrue(pickerSource.contains("minHeight: 34"))
        XCTAssertTrue(pickerSource.contains("RoundedInteractionButtonStyle(cornerRadius: 7)"))
        XCTAssertFalse(pickerSource.contains("isSelected: accessMode == selectedAccessMode"))
        XCTAssertTrue(pickerSource.contains(
            "Text(accessMode.composerTitle)\n                        Spacer(minLength: 8)\n                        Image(systemName: \"checkmark\")"
        ))
    }

    func testAssistantMarkdownOverridesGitHubOpaqueTextBackground() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private let assistantMarkdownTheme = Theme.gitHub"))
        XCTAssertTrue(source.contains(".markdownTheme(assistantMarkdownTheme)"))
        XCTAssertFalse(source.contains(".markdownTheme(.gitHub)"))
    }

    func testAssistantMarkdownUsesQuietThematicBreaks() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".thematicBreak {"))
        XCTAssertTrue(source.contains("Color.primary.opacity(0.12)"))
        XCTAssertTrue(source.contains(".frame(height: 1)"))
        XCTAssertTrue(source.contains(".markdownMargin(top: 14, bottom: 14)"))
    }

    func testAssistantMarkdownUsesTranslucentInlineCodeBackground() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".code {"))
        XCTAssertTrue(source.contains("BackgroundColor(Color.primary.opacity(0.07))"))
    }

    func testAssistantMarkdownUsesTranslucentTableSurfaces() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".table { configuration in"))
        XCTAssertTrue(source.contains("color: Color.primary.opacity(0.10)"))
        XCTAssertTrue(source.contains("Color.primary.opacity(0.055)"))
        XCTAssertTrue(source.contains("Color.primary.opacity(0.025)"))
        XCTAssertTrue(source.contains("header: Color.primary.opacity(0.075)"))
    }

    func testAssistantRepliesRenderAsFlatCopyableTimeline() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        let timelineStart = try XCTUnwrap(source.range(of: "private var assistantTimeline"))
        let timelineEnd = try XCTUnwrap(
            source.range(
                of: "private var copyMessageLabel",
                range: timelineStart.upperBound..<source.endIndex
            )
        )
        let timelineSource = source[timelineStart.lowerBound..<timelineEnd.lowerBound]

        XCTAssertTrue(timelineSource.contains("Text(timestamp, style: .time)"))
        XCTAssertTrue(timelineSource.contains("Button(action: copyMessage)"))
        XCTAssertFalse(timelineSource.contains(".background(AppPalette.translucentSurface"))
        XCTAssertFalse(timelineSource.contains(".adaptiveCornerRadius(18)"))
        XCTAssertTrue(source.contains("MessageClipboard.copy(message.copyableText)"))
        XCTAssertTrue(source.contains("L10n.string(\"chat.message.copy\")"))
    }

    func testMessageClipboardCopiesTheExactResponseText() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("pi-work-copy-test-\(UUID().uuidString)")
        )

        XCTAssertTrue(MessageClipboard.copy("第一行\n第二行", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "第一行\n第二行")
    }

    func testMessageCopyFeedbackUsesACheckmarkForThreeSeconds() {
        XCTAssertEqual(MessageCopyFeedback.iconName(isCopied: false), "doc.on.doc")
        XCTAssertEqual(MessageCopyFeedback.iconName(isCopied: true), "checkmark")
        XCTAssertEqual(MessageCopyFeedback.resetDelayNanoseconds, 3_000_000_000)
    }

    func testAssistantCopyButtonWiresSuccessfulCopyFeedback() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var isMessageCopied = false"))
        XCTAssertTrue(source.contains("MessageCopyFeedback.iconName"))
        XCTAssertTrue(source.contains("copyFeedbackResetTask"))
        XCTAssertTrue(source.contains("L10n.string(\"chat.message.copied\")"))
    }

    func testAssistantTimelinePlacesCopyBeforeTimestampAtLeadingEdge() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let timelineStart = try XCTUnwrap(source.range(of: "private var assistantTimeline"))
        let timelineEnd = try XCTUnwrap(
            source.range(
                of: "private var copyMessageLabel",
                range: timelineStart.upperBound..<source.endIndex
            )
        )
        let timelineSource = source[timelineStart.lowerBound..<timelineEnd.lowerBound]
        let footerStart = try XCTUnwrap(timelineSource.range(of: "HStack(spacing: 8)"))
        let footerSource = timelineSource[footerStart.lowerBound...]
        let copyStart = try XCTUnwrap(
            footerSource.range(of: "Button(action: copyMessage)")
        )
        let timestampStart = try XCTUnwrap(footerSource.range(of: "if let timestamp"))
        let trailingSpacer = try XCTUnwrap(footerSource.range(of: "Spacer(minLength: 8)"))

        XCTAssertLessThan(copyStart.lowerBound, timestampStart.lowerBound)
        XCTAssertLessThan(timestampStart.lowerBound, trailingSpacer.lowerBound)
    }

    func testConversationSurfaceExposesSearchableModelAndThinkingControls() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("model-picker-search"))
        XCTAssertTrue(source.contains("model-picker-scroll-view"))
        XCTAssertTrue(source.contains("session-thinking-level"))
        XCTAssertTrue(source.contains("availableThinkingLevels"))
    }

    func testComposerKeepsModelAndThinkingControlsTightlyGrouped() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let editorStart = try XCTUnwrap(source.range(of: "private var editor: some View"))
        let editorEnd = try XCTUnwrap(
            source.range(
                of: "private var imageAttachmentStrip",
                range: editorStart.upperBound..<source.endIndex
            )
        )
        let editorSource = source[editorStart.lowerBound..<editorEnd.lowerBound]

        XCTAssertTrue(editorSource.contains("HStack(spacing: 4) {\n                    modelPicker"))
        XCTAssertTrue(editorSource.contains("thinkingLevelMenu(selectedThinkingLevel)"))
    }

    func testThinkingLevelButtonHasNoDefaultFill() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let menuStart = try XCTUnwrap(source.range(of: "private func thinkingLevelMenu"))
        let pickerStart = try XCTUnwrap(
            source.range(
                of: "private func thinkingLevelPickerContent",
                range: menuStart.upperBound..<source.endIndex
            )
        )
        let menuSource = source[menuStart.lowerBound..<pickerStart.lowerBound]

        XCTAssertFalse(menuSource.contains(".background("))
        XCTAssertFalse(menuSource.contains("isThinkingMenuHovering"))
    }

    func testSharedChatAndWorkComposerOmitsVoiceInputButton() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let editorStart = try XCTUnwrap(source.range(of: "private var editor: some View"))
        let editorEnd = try XCTUnwrap(
            source.range(
                of: "private var selectedSlashCommandTokenWidth",
                range: editorStart.upperBound..<source.endIndex
            )
        )
        let editorSource = source[editorStart.lowerBound..<editorEnd.lowerBound]

        XCTAssertFalse(editorSource.contains("Image(systemName: \"mic\")"))
    }

    func testModelPickerUsesOfficialIconsAndCompactWidth() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Image(model.providerIconAssetName)"))
        XCTAssertTrue(source.contains(".renderingMode(.template)"))
        XCTAssertTrue(source.contains(".foregroundStyle(Color.primary)"))
        XCTAssertTrue(source.contains(".frame(width: 260)"))
        XCTAssertFalse(source.contains(".frame(width: 272)"))
        XCTAssertFalse(source.contains(".frame(width: 330)"))
        XCTAssertFalse(source.contains("Image(systemName: model.providerIconName)"))
    }

    func testModelPickerUsesCompactSearchAndMenuRows() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let contentStart = try XCTUnwrap(source.range(of: "private var modelPickerContent"))
        let rowStart = try XCTUnwrap(
            source.range(of: "private func modelPickerRow", range: contentStart.upperBound..<source.endIndex)
        )
        let fastButtonStart = try XCTUnwrap(
            source.range(of: "private func fastModeButton", range: rowStart.upperBound..<source.endIndex)
        )
        let contentSource = source[contentStart.lowerBound..<rowStart.lowerBound]
        let rowSource = source[rowStart.lowerBound..<fastButtonStart.lowerBound]

        XCTAssertTrue(contentSource.contains("RoundedRectangle(cornerRadius: 8, style: .continuous)"))
        XCTAssertFalse(contentSource.contains("Divider()"))
        XCTAssertTrue(contentSource.contains(".frame(width: 260)"))
        XCTAssertTrue(rowSource.contains("minHeight: 34"))
        XCTAssertTrue(rowSource.contains("RoundedInteractionButtonStyle(cornerRadius: 7)"))
        XCTAssertFalse(rowSource.contains("isSelected: model == selectedModel"))
        XCTAssertTrue(rowSource.contains(
            "Text(model.displayName)\n                        .lineLimit(1)\n                    Spacer(minLength: 8)\n                    Image(systemName: \"checkmark\")"
        ))
    }

    func testComposerModelPickerOmitsCurrentModelIcon() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let pickerStart = try XCTUnwrap(source.range(of: "private var modelPicker"))
        let contentStart = try XCTUnwrap(
            source.range(of: "private var modelPickerContent", range: pickerStart.upperBound..<source.endIndex)
        )
        let pickerSource = source[pickerStart.lowerBound..<contentStart.lowerBound]

        XCTAssertFalse(pickerSource.contains("ModelProviderIcon"))
        XCTAssertFalse(pickerSource.contains("Image(systemName: \"bolt.fill\")"))
    }

    func testModelSelectionHighlightExcludesFastModeControl() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let rowStart = try XCTUnwrap(source.range(of: "private func modelPickerRow"))
        let fastButtonStart = try XCTUnwrap(
            source.range(of: "private func fastModeButton", range: rowStart.upperBound..<source.endIndex)
        )
        let rowSource = source[rowStart.lowerBound..<fastButtonStart.lowerBound]

        XCTAssertFalse(rowSource.contains("isSelected: model == selectedModel"))
        XCTAssertTrue(rowSource.contains("RoundedInteractionButtonStyle(cornerRadius: 7)"))
        XCTAssertFalse(rowSource.contains(".background("))
        XCTAssertTrue(rowSource.contains("fastModeButton(for: model)"))
    }

    func testFastModeControlUsesSlidingCapsule() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let fastButtonStart = try XCTUnwrap(source.range(of: "private func fastModeButton"))
        let filteredModelsStart = try XCTUnwrap(
            source.range(of: "private var filteredModels", range: fastButtonStart.upperBound..<source.endIndex)
        )
        let fastButtonSource = source[fastButtonStart.lowerBound..<filteredModelsStart.lowerBound]
        let switchStart = try XCTUnwrap(source.range(of: "private struct FastModeCapsuleSwitch"))
        let providerIconStart = try XCTUnwrap(
            source.range(of: "private struct ModelProviderIcon", range: switchStart.upperBound..<source.endIndex)
        )
        let switchSource = source[switchStart.lowerBound..<providerIconStart.lowerBound]

        XCTAssertTrue(fastButtonSource.contains("FastModeCapsuleSwitch("))
        XCTAssertTrue(fastButtonSource.contains(".opacity(model.supportsFastMode ? 1 : 0)"))
        XCTAssertTrue(fastButtonSource.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(fastButtonSource.contains("isModelPickerPresented = false"))
        XCTAssertTrue(switchSource.contains("Capsule()"))
        XCTAssertTrue(switchSource.contains("Circle()"))
        XCTAssertTrue(switchSource.contains(".offset(x: isOn ? 7 : -7)"))
        XCTAssertTrue(switchSource.contains("value: isOn"))
    }

    func testLobeHubModelIconAssetsArePresent() {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetCatalog = repositoryRoot.appendingPathComponent(
            "PiWork/Resources/Assets.xcassets"
        )
        let assetNames = [
            "ModelIconClaude",
            "ModelIconCohere",
            "ModelIconDeepSeek",
            "ModelIconGemini",
            "ModelIconGemma",
            "ModelIconGrok",
            "ModelIconKimi",
            "ModelIconLobeHub",
            "ModelIconMeta",
            "ModelIconMicrosoft",
            "ModelIconMiniMax",
            "ModelIconMistral",
            "ModelIconNova",
            "ModelIconNVIDIA",
            "ModelIconOpenAI",
            "ModelIconQwen",
            "ModelIconStepFun",
            "ModelIconXiaomiMiMo",
            "ModelIconZAI"
        ]

        for assetName in assetNames {
            let manifest = assetCatalog
                .appendingPathComponent("\(assetName).imageset")
                .appendingPathComponent("Contents.json")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: manifest.path),
                "Missing LobeHub icon asset: \(assetName)"
            )
            let manifestContents = try? String(contentsOf: manifest, encoding: .utf8)
            XCTAssertTrue(
                manifestContents?.contains("\"template-rendering-intent\" : \"template\"") == true,
                "LobeHub icon must adapt to light and dark appearance: \(assetName)"
            )
        }
    }

    func testGeminiUsesRasterAssetToAvoidCoreSVGRenderingRegression() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = repositoryRoot
            .appendingPathComponent("PiWork/Resources/Assets.xcassets/ModelIconGemini.imageset")
            .appendingPathComponent("Contents.json")
        let manifestContents = try String(contentsOf: manifest, encoding: .utf8)

        XCTAssertTrue(manifestContents.contains("\"filename\" : \"gemini.png\""))
        XCTAssertFalse(manifestContents.contains(".svg"))
    }

    func testThinkingPickerRequestsUpwardPopoverPlacement() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                ".popover(isPresented: $isThinkingPickerPresented, arrowEdge: .bottom)"
            )
        )
    }

    func testThinkingPickerUsesHorizontalEffortSlider() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Slider("))
        XCTAssertTrue(source.contains("L10n.string(\"chat.faster\")"))
        XCTAssertTrue(source.contains("L10n.string(\"chat.smarter\")"))
    }

    func testEveryModelRowShowsCapabilityAwareFastButton() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let editorStart = try XCTUnwrap(source.range(of: "private var editor"))
        let pickerStart = try XCTUnwrap(
            source.range(of: "private var modelPicker", range: editorStart.upperBound..<source.endIndex)
        )
        let rowStart = try XCTUnwrap(source.range(of: "private func modelPickerRow"))
        let rowEnd = try XCTUnwrap(
            source.range(of: "private var filteredModels", range: rowStart.upperBound..<source.endIndex)
        )
        let editorSource = source[editorStart.lowerBound..<pickerStart.lowerBound]
        let rowSource = source[rowStart.lowerBound..<rowEnd.lowerBound]

        XCTAssertFalse(editorSource.contains("fastModeToggle"))
        XCTAssertFalse(rowSource.contains("if model == selectedModel"))
        XCTAssertTrue(rowSource.contains("fastModeButton(for: model)"))
        XCTAssertTrue(source.contains("FastModeCapsuleSwitch("))
        XCTAssertTrue(source.contains(".disabled(!model.supportsFastMode)"))
        XCTAssertTrue(source.contains("model == selectedModel && modelOptions.fastMode.enabled"))
        XCTAssertTrue(source.contains("onToggleFastMode(model)"))
    }

    func testThinkingPickerKeepsOnlyOneMillionContextSwitch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )
        let pickerStart = try XCTUnwrap(
            source.range(of: "private func thinkingLevelPickerContent")
        )
        let pickerEnd = try XCTUnwrap(
            source.range(of: "private func modelOptionToggle", range: pickerStart.upperBound..<source.endIndex)
        )
        let pickerSource = source[pickerStart.lowerBound..<pickerEnd.lowerBound]

        XCTAssertTrue(pickerSource.contains("L10n.string(\"chat.one_million_context\")"))
        XCTAssertTrue(pickerSource.contains("one-million-context-toggle"))
        XCTAssertFalse(pickerSource.contains("Text(\"Fast 模式\")"))
        XCTAssertFalse(pickerSource.contains("option: .fastMode"))
    }

    func testComposerExposesContextUsageIndicatorAndHoverDetails() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("ContextUsageIndicator"))
        XCTAssertTrue(source.contains("context-usage-indicator"))
        XCTAssertTrue(source.contains(".popover(isPresented: $isContextUsagePresented"))
    }

    func testConversationSurfaceUsesSharedSessionStoreForChatAndWork() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("selectedWorkSessionIdByProjectPath"))
        XCTAssertFalse(source.contains("@StateObject private var viewModel"))
    }

    func testProjectPickerOpensAboveComposer() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("isPresented: $isProjectPickerPresented"))
        XCTAssertTrue(source.contains("SessionComposerState.projectPickerPopoverAnchorX("))
        XCTAssertTrue(source.contains("arrowEdge: .top"))
        XCTAssertTrue(
            source.contains(
                ".frame(width: SessionComposerState.projectPickerPopoverWidth)"
            )
        )
    }

    func testProjectPickerPopoverAlignsWithComposerLeadingEdge() {
        let composerWidth: CGFloat = 640
        let popoverWidth = SessionComposerState.projectPickerPopoverWidth
        let anchorX = SessionComposerState.projectPickerPopoverAnchorX(
            composerWidth: composerWidth
        )

        XCTAssertEqual(
            anchorX * composerWidth - popoverWidth / 2,
            0,
            accuracy: 0.001
        )
    }

    func testProjectBarOmitsRedundantLocalIndicator() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Label(\"本地\", systemImage: \"laptopcomputer\")"))
    }

    func testProjectBarUsesSearchableCreationOnlyGitBranchPicker() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Chat/Views/ChatView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("GitBranchIcon"))
        XCTAssertTrue(source.contains("branch-picker-search"))
        XCTAssertTrue(source.contains("branch-picker-scroll-view"))
        XCTAssertTrue(source.contains("canSelectGitBranch"))
        XCTAssertTrue(source.contains("await sessionStore.gitBranches"))
        XCTAssertTrue(source.contains("await sessionStore.setGitBranch"))
        XCTAssertFalse(source.contains("private enum ProjectMetadata"))
        XCTAssertFalse(source.contains("appendingPathComponent(\"HEAD\")"))
    }

    func testEditorHeightClampsBetweenTwoAndFourLines() {
        XCTAssertEqual(SessionComposerState.editorHeight(for: 0), 44)
        XCTAssertEqual(SessionComposerState.editorHeight(for: 62), 62)
        XCTAssertEqual(SessionComposerState.editorHeight(for: 120), 80)
        XCTAssertFalse(SessionComposerState.editorShouldScroll(contentHeight: 80))
        XCTAssertTrue(SessionComposerState.editorShouldScroll(contentHeight: 81))
    }

    func testReturnSubmitsMessage() {
        XCTAssertEqual(
            SessionComposerState.returnKeyAction(
                isShiftPressed: false,
                hasMarkedText: false
            ),
            .submit
        )
    }

    func testShiftReturnInsertsNewline() {
        XCTAssertEqual(
            SessionComposerState.returnKeyAction(
                isShiftPressed: true,
                hasMarkedText: false
            ),
            .insertNewline
        )
    }

    func testReturnDefersToActiveInputMethod() {
        XCTAssertEqual(
            SessionComposerState.returnKeyAction(
                isShiftPressed: false,
                hasMarkedText: true
            ),
            .deferToInputMethod
        )
    }

    @MainActor
    func testComposerPreservesMarkedTextDuringSwiftUIUpdate() throws {
        let view = ChatView(
            mode: .work,
            projects: [],
            selectedProject: .constant(nil),
            sessionStore: makeInactiveSessionStore(),
            onAddFolder: {}
        )
        .frame(width: 646, height: 600)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 646, height: 600)
        hostingView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(hostingView.firstDescendant(of: NSTextView.self))
        textView.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertTrue(textView.hasMarkedText())
        hostingView.rootView = view
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(textView.string, "ni")
        XCTAssertTrue(textView.hasMarkedText())
    }

    func testComposerBorderRemainsNeutral() {
        XCTAssertEqual(SessionComposerState.borderOpacity(isHovering: false), 0.09)
        XCTAssertEqual(SessionComposerState.borderOpacity(isHovering: true), 0.16)
        XCTAssertEqual(SessionComposerState.borderWidth, 0.5)
    }

    @MainActor
    func testHomeShowsEverySuggestionAtMinimumContentWidth() throws {
        let view = ChatView(
            mode: .work,
            projects: [],
            selectedProject: .constant(nil),
            sessionStore: makeInactiveSessionStore(),
            onAddFolder: {}
        )
        .frame(width: 646, height: 600)
        .environment(\.colorScheme, .light)

        let bitmap = try TestViewRenderer.render(view, size: CGSize(width: 646, height: 600))

        XCTAssertGreaterThan(
            bitmap.countPixels { color in
                color.redComponent > 0.75
                    && color.greenComponent > 0.25
                    && color.greenComponent < 0.75
                    && color.blueComponent < 0.35
            },
            0,
            "The orange fourth suggestion must be visible without horizontal scrolling"
        )
    }

    @MainActor
    func testComposerStartsAtCompactTwoLineHeight() throws {
        let view = ChatView(
            mode: .work,
            projects: [],
            selectedProject: .constant(nil),
            sessionStore: makeInactiveSessionStore(),
            onAddFolder: {}
        )
        .frame(width: 646, height: 600)
        .background(Color.gray)
        .environment(\.colorScheme, .light)

        let bitmap = try TestViewRenderer.render(view, size: CGSize(width: 646, height: 600))
        let editorHeight = bitmap.longestVerticalRun(atX: 323, in: 350..<590) { color in
            color.redComponent > 0.92
                && color.greenComponent > 0.92
                && color.blueComponent > 0.92
        }

        XCTAssertLessThanOrEqual(editorHeight, 120)
    }

}

private func makeComposerTestImageData(
    width: Int,
    height: Int,
    red: CGFloat = 0.4
) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(red: red, green: 0.35, blue: 0.75, alpha: 0.8)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(
        CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private func makeHostModel(provider: String, id: String, name: String) -> AgentHostModel {
    AgentHostModel(
        provider: provider,
        id: id,
        name: name,
        contextWindow: 128_000,
        maxTokens: 16_384,
        reasoning: true,
        supportsImages: true
    )
}

@MainActor
private func makeInactiveSessionStore() -> SessionStore {
    SessionStore(
        service: AgentHostService(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            requiredCapabilities: []
        )
    )
}

enum TestViewRenderer {
    @MainActor
    static func render<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let hostingView = host(view, size: size)

        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private static func host<V: View>(_ view: V, size: CGSize) -> NSHostingView<V> {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView
    }
}

private extension NSBitmapImageRep {
    func countPixels(matching predicate: (NSColor) -> Bool) -> Int {
        var count = 0
        for y in 0..<pixelsHigh {
            for x in 0..<pixelsWide {
                guard
                    let color = colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    color.alphaComponent > 0.5,
                    predicate(color)
                else { continue }
                count += 1
            }
        }
        return count
    }

    func longestVerticalRun(
        atX x: Int,
        in rows: Range<Int>,
        matching predicate: (NSColor) -> Bool
    ) -> Int {
        var longest = 0
        var current = 0

        for y in rows {
            guard
                let color = colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                color.alphaComponent > 0.5,
                predicate(color)
            else {
                longest = max(longest, current)
                current = 0
                continue
            }
            current += 1
        }

        return max(longest, current)
    }
}

private extension NSView {
    func firstDescendant<View: NSView>(of type: View.Type) -> View? {
        if let match = self as? View { return match }
        return subviews.lazy.compactMap { $0.firstDescendant(of: type) }.first
    }
}
