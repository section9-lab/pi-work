import Foundation

enum SessionComposerPrimaryAction: Equatable {
    case none
    case send
    case stop
}

enum SessionComposerReturnKeyAction: Equatable {
    case submit
    case insertNewline
    case deferToInputMethod
}

enum SessionComposerEditorCommand {
    case confirmSuggestion
    case selectPreviousSuggestion
    case selectNextSuggestion
    case dismissSuggestions
    case deleteSelectedCommand
    case recallPreviousPrompt
    case recallNextPrompt
}

enum SessionComposerHistoryDirection {
    case previous
    case next
}

struct SessionComposerRecalledPrompt: Equatable {
    let draft: String
    let selectedCommand: AgentHostSlashCommand?
}

struct SessionComposerPromptHistoryNavigation {
    private var index: Int?
    private var draftBeforeNavigation: String?

    mutating func previous(in prompts: [String], currentDraft: String) -> String? {
        guard !prompts.isEmpty else { return nil }
        let nextIndex: Int
        if let index {
            nextIndex = max(min(index, prompts.count - 1) - 1, 0)
        } else {
            draftBeforeNavigation = currentDraft
            nextIndex = prompts.count - 1
        }
        index = nextIndex
        return prompts[nextIndex]
    }

    mutating func next(in prompts: [String]) -> String? {
        guard let index else { return nil }
        if index < prompts.count - 1 {
            self.index = index + 1
            return prompts[index + 1]
        }
        self.index = nil
        let draft = draftBeforeNavigation ?? ""
        draftBeforeNavigation = nil
        return draft
    }

    mutating func reset() {
        index = nil
        draftBeforeNavigation = nil
    }
}

enum SessionComposerState {
    static let minimumEditorHeight: CGFloat = 44
    static let maximumEditorHeight: CGFloat = 80
    static let borderWidth: CGFloat = 0.5
    static let maximumVisibleModelRows = 5
    static let maximumVisibleGitBranchRows = 5
    static let slashTokenSpacing: CGFloat = 8
    static let projectPickerPopoverWidth: CGFloat = 210

    static func projectPickerPopoverAnchorX(composerWidth: CGFloat) -> CGFloat {
        guard composerWidth > 0 else { return 0.5 }
        return min(projectPickerPopoverWidth / (2 * composerWidth), 1)
    }

    static func primaryAction(
        draft: String,
        hasAttachments: Bool = false,
        isExecuting: Bool
    ) -> SessionComposerPrimaryAction {
        if isExecuting { return .stop }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments
            ? .none
            : .send
    }

    static func canSend(
        baseCanSend: Bool,
        hasAttachments: Bool,
        isProcessingAttachments: Bool,
        selectedModelSupportsImages: Bool
    ) -> Bool {
        guard baseCanSend, !isProcessingAttachments else { return false }
        return !hasAttachments || selectedModelSupportsImages
    }

    static func promptHistory(in messages: [PiChatMessage]) -> [String] {
        messages.compactMap { message in
            guard message.role == .user else { return nil }
            let text = message.copyableText
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }

    static func editorHeight(for contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, minimumEditorHeight), maximumEditorHeight)
    }

    static func editorShouldScroll(contentHeight: CGFloat) -> Bool {
        contentHeight > maximumEditorHeight
    }

    static func returnKeyAction(
        isShiftPressed: Bool,
        hasMarkedText: Bool
    ) -> SessionComposerReturnKeyAction {
        if hasMarkedText { return .deferToInputMethod }
        return isShiftPressed ? .insertNewline : .submit
    }

    static func borderOpacity(isHovering: Bool) -> Double {
        isHovering ? 0.16 : 0.09
    }

    static func filteredModels(
        _ models: [PiModelOption],
        query: String
    ) -> [PiModelOption] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter { model in
            model.displayName.localizedCaseInsensitiveContains(query)
                || model.provider.localizedCaseInsensitiveContains(query)
                || model.modelID.localizedCaseInsensitiveContains(query)
        }
    }

    static func filteredGitBranches(
        _ branches: [String],
        query: String
    ) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    static func visibleGitBranchRowCount(resultCount: Int) -> Int {
        min(max(resultCount, 0), maximumVisibleGitBranchRows)
    }

    static func slashQuery(in draft: String, mode: SidebarTab) -> String? {
        guard mode == .work, draft.hasPrefix("/") else { return nil }
        return String(draft.dropFirst().prefix { !$0.isWhitespace })
    }

    static func filteredSlashCommands(
        _ commands: [AgentHostSlashCommand],
        query: String
    ) -> [AgentHostSlashCommand] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commands }
        return commands.filter { command in
            command.name.localizedCaseInsensitiveContains(query)
                || command.displayName.localizedCaseInsensitiveContains(query)
                || command.description?.localizedCaseInsensitiveContains(query) == true
                || command.source.rawValue.localizedCaseInsensitiveContains(query)
                || command.source.composerKindTitle.localizedCaseInsensitiveContains(query)
        }
    }

    static func draftAfterSelectingSlashCommand(from draft: String) -> String {
        guard draft.hasPrefix("/") else { return draft }
        let content = draft.dropFirst()
        guard let separator = content.firstIndex(where: \.isWhitespace) else { return "" }
        return String(content[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func submissionText(
        draft: String,
        selectedCommand: AgentHostSlashCommand?
    ) -> String {
        guard let selectedCommand else { return draft }
        return draft.isEmpty ? "/\(selectedCommand.name)" : "/\(selectedCommand.name) \(draft)"
    }

    static func slashTokenExclusionRect(
        tokenWidth: CGFloat,
        lineHeight: CGFloat
    ) -> CGRect {
        guard tokenWidth > 0, lineHeight > 0 else { return .zero }
        return CGRect(
            x: 0,
            y: 0,
            width: tokenWidth + slashTokenSpacing,
            height: lineHeight
        )
    }

    static func shouldNavigatePromptHistory(
        _ direction: SessionComposerHistoryDirection,
        in text: String,
        selection: NSRange,
        hasMarkedText: Bool = false
    ) -> Bool {
        let value = text as NSString
        guard
            !hasMarkedText,
            selection.length == 0,
            selection.location <= value.length
        else { return false }
        let adjacentText: String
        switch direction {
        case .previous:
            adjacentText = value.substring(to: selection.location)
        case .next:
            adjacentText = value.substring(from: selection.location)
        }
        return adjacentText.rangeOfCharacter(from: .newlines) == nil
    }

    static func recalledPrompt(
        _ prompt: String,
        commands: [AgentHostSlashCommand]
    ) -> SessionComposerRecalledPrompt {
        for command in commands.sorted(by: { $0.name.count > $1.name.count }) {
            let invocation = "/\(command.name)"
            guard prompt.hasPrefix(invocation) else { continue }
            let remainder = prompt.dropFirst(invocation.count)
            guard remainder.isEmpty || remainder.first?.isWhitespace == true else { continue }
            return SessionComposerRecalledPrompt(
                draft: String(remainder.drop(while: \.isWhitespace)),
                selectedCommand: command
            )
        }
        return SessionComposerRecalledPrompt(draft: prompt, selectedCommand: nil)
    }

    static func visibleModelRowCount(resultCount: Int) -> Int {
        min(max(resultCount, 0), maximumVisibleModelRows)
    }

    static func thinkingLevel(
        forSliderValue value: Double,
        availableLevels: [AgentHostThinkingLevel]
    ) -> AgentHostThinkingLevel? {
        guard !availableLevels.isEmpty else { return nil }
        let index = min(
            max(Int(value.rounded()), 0),
            availableLevels.count - 1
        )
        return availableLevels[index]
    }
}

extension AgentHostSlashCommand {
    var displayName: String {
        let value = source == .skill && name.hasPrefix("skill:")
            ? String(name.dropFirst("skill:".count))
            : name
        return value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

extension AgentHostSlashCommandSource {
    var composerIcon: String {
        switch self {
        case .agent: return "command"
        case .skill: return "doc.text"
        case .extensionCommand: return "puzzlepiece.extension"
        }
    }

    var composerKindTitle: String {
        switch self {
        case .agent: return L10n.string("settings.sidebar.agent")
        case .skill: return L10n.string("sidebar.skills")
        case .extensionCommand: return L10n.string("sidebar.extensions")
        }
    }
}

extension AgentHostAccessMode {
    var composerTitle: String {
        switch self {
        case .none: return L10n.string("access.none.title")
        case .readOnly: return L10n.string("access.read_only.title")
        case .ask: return L10n.string("access.ask.title")
        case .full: return L10n.string("access.full.title")
        }
    }

    var composerDescription: String {
        switch self {
        case .none: return L10n.string("access.none.description")
        case .readOnly: return L10n.string("access.read_only.description")
        case .ask: return L10n.string("access.ask.description")
        case .full: return L10n.string("access.full.description")
        }
    }

    var composerIcon: String {
        switch self {
        case .none: return "shield.slash"
        case .readOnly: return "eye"
        case .ask: return "hand.raised"
        case .full: return "shield.checkered"
        }
    }

    static let workChoices: [AgentHostAccessMode] = [.ask, .full]
}

extension AgentHostThinkingLevel {
    var composerTitle: String {
        switch self {
        case .off: return L10n.string("settings.thinking.off")
        case .minimal: return L10n.string("settings.thinking.minimal")
        case .low: return L10n.string("settings.thinking.low")
        case .medium: return L10n.string("settings.thinking.medium")
        case .high: return L10n.string("settings.thinking.high")
        case .xhigh: return L10n.string("settings.thinking.xhigh")
        case .max: return L10n.string("settings.thinking.max")
        }
    }
}
