import AppKit
import MarkdownUI
import SwiftUI

/// One conversation surface shared by Chat and Work. Chat owns an isolated
/// application-support working directory; Work only creates an agent after
/// the user has selected a linked project.
struct ChatView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject private var sessionStore: SessionStore
    @Binding private var selectedProject: PiProject?

    let mode: SidebarTab
    let projects: [PiProject]
    let hostError: String?
    let isLoadingSession: Bool
    let onSelectProject: (PiProject) -> Void
    let onAddFolder: () -> Void

    @State private var draft = ""
    @State private var selectedSlashCommand: AgentHostSlashCommand?
    @State private var slashCommands: [AgentHostSlashCommand] = []
    @State private var imageAttachments: [ComposerImageAttachment] = []
    @State private var isProcessingImageAttachments = false
    @State private var imageProcessingID: UUID?
    @State private var actionError: String?
    @State private var gitBranches = AgentHostGitBranchesResult.unavailable
    @State private var isFollowingTranscriptTail = true
    @State private var isTranscriptAutoFollowPaused = false
    @State private var isAdjustingTranscriptScroll = false
    @State private var transcriptScrollRequest = 0
    @State private var transcriptMessageLimit = TranscriptWindow.batchSize
    @State private var presentedSessionID: String?
    @State private var readySessionPresentationID: String?
    @State private var presentedMessageLimit = TranscriptWindow.batchSize
    @State private var isPreparingSessionPresentation = false
    @State private var loadedToolOutputs: [String: String] = [:]
    @State private var loadingToolOutputIDs: Set<String> = []

    init(
        mode: SidebarTab,
        projects: [PiProject],
        selectedProject: Binding<PiProject?>,
        sessionStore: SessionStore,
        hostError: String? = nil,
        isLoadingSession: Bool = false,
        onSelectProject: @escaping (PiProject) -> Void = { _ in },
        onAddFolder: @escaping () -> Void
    ) {
        self.mode = mode
        self.projects = projects
        self._selectedProject = selectedProject
        self._sessionStore = ObservedObject(wrappedValue: sessionStore)
        self.hostError = hostError
        self.isLoadingSession = isLoadingSession
        self.onSelectProject = onSelectProject
        self.onAddFolder = onAddFolder
    }

    var body: some View {
        let messagePresentation = messagePresentation
        let allMessages = messagePresentation.messages
        VStack(spacing: 0) {
            ZStack {
                Group {
                    if allMessages.isEmpty {
                        emptySession
                            .transition(.opacity)
                    } else {
                        transcript(
                            messages: allMessages,
                            hiddenMessageCount: messagePresentation.hiddenCount
                        )
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(!isSessionTransitioning)
                .accessibilityHidden(isSessionTransitioning)
                .opacity(isSessionTransitioning ? 0 : 1)
                .animation(nil, value: isSessionTransitioning)

                if isSessionTransitioning {
                    SessionTranscriptLoadingMask()
                        .transition(.opacity)
                }
            }
            .animation(
                accessibilityReduceMotion ? nil : .easeOut(duration: 0.18),
                value: isSessionTransitioning
            )

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }

            SessionComposer(
                sessionIdentity: sessionPresentationID,
                mode: mode,
                projects: projects,
                selectedProject: $selectedProject,
                draft: $draft,
                selectedSlashCommand: $selectedSlashCommand,
                slashCommands: slashCommands,
                promptHistory: SessionComposerState.promptHistory(in: allMessages),
                imageAttachments: imageAttachments,
                isProcessingImageAttachments: isProcessingImageAttachments,
                selectedModelSupportsImages: selectedModelSupportsImages,
                isExecuting: isExecuting,
                canSend: canSend,
                availableModels: availableModels,
                selectedModel: selectedModel,
                selectedModelName: selectedModelName,
                contextUsage: activeRecord?.contextUsage,
                plan: activeRecord?.acpState.plan ?? [],
                extensionStatuses: activeRecord?.acpState.extensionStatuses ?? [:],
                extensionWidgets: activeRecord?.acpState.extensionWidgets ?? [:],
                cost: activeRecord?.acpState.cost,
                selectedThinkingLevel: activeRecord?.thinkingLevel,
                availableThinkingLevels: activeRecord?.availableThinkingLevels ?? [],
                modelOptions: activeRecord?.modelOptions ?? .unsupported,
                genericConfigOptions: activeRecord?.acpState.genericConfigOptions ?? [],
                genericModeState: activeRecord?.acpState.genericModeState,
                selectedAccessMode: activeRecord?.accessMode,
                gitBranches: gitBranches.branches,
                isGitAvailable: gitBranches.available,
                selectedGitBranch: activeRecord?.gitBranch,
                canSelectGitBranch: activeRecord?.messages.isEmpty == true,
                onAddFolder: onAddFolder,
                onSelectProject: onSelectProject,
                onSelectGitBranch: selectGitBranch,
                onSelectModel: selectModel,
                onToggleFastMode: toggleFastMode,
                onSelectThinkingLevel: selectThinkingLevel,
                onSelectModelOption: selectModelOption,
                onSelectConfigOption: selectConfigOption,
                onSelectSessionMode: selectSessionMode,
                onSelectAccessMode: selectAccessMode,
                onPasteboard: handlePasteboard,
                onRemoveImage: removeImageAttachment,
                onSend: send,
                onStop: stopGeneration
            )
            .frame(maxWidth: 900)
            .disabled(isSessionTransitioning)
            .overlay {
                if isSessionTransitioning {
                    SessionComposerLoadingMask()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .top) {
            if !isLoadingSession, !isPreparingSessionPresentation, !allMessages.isEmpty {
                VStack(spacing: 0) {
                    AppPalette.transcriptTopFadeSurface
                        .frame(height: 32)

                    AppPalette.transcriptTopFadeSurface
                        .mask(
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 32)
                }
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task(id: activeSessionId) {
            await loadSlashCommands()
        }
        .task(id: gitBranchLoadID) {
            await loadGitBranches()
        }
        .task(id: sessionPresentationID) {
            guard activeSessionId != nil else {
                presentedSessionID = nil
                readySessionPresentationID = nil
                isPreparingSessionPresentation = false
                return
            }
            let presentationID = sessionPresentationID
            if let activeSessionId {
                sessionStore.markActiveSessionOpenPerformance(
                    sessionID: activeSessionId,
                    stage: .presentationStarted
                )
            }
            isPreparingSessionPresentation = true
            await Task.yield()

            draft = ""
            selectedSlashCommand = nil
            imageAttachments.removeAll()
            isProcessingImageAttachments = false
            imageProcessingID = nil
            actionError = nil
            gitBranches = .unavailable
            transcriptMessageLimit = TranscriptWindow.batchSize
            presentedMessageLimit = SessionPresentationBatch.initialCount
            presentedSessionID = activeSessionId
            loadedToolOutputs.removeAll()
            loadingToolOutputIDs.removeAll()
            isTranscriptAutoFollowPaused = false
            isFollowingTranscriptTail = true
            transcriptScrollRequest &+= 1
            await Task.yield()

            // The whole window renders in one pass; a single frame is enough for
            // layout to settle before pinning the scroll view to the tail.
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            transcriptScrollRequest &+= 1
            await Task.yield()
            readySessionPresentationID = presentationID
            isPreparingSessionPresentation = false
            if let activeSessionId {
                sessionStore.markActiveSessionOpenPerformance(
                    sessionID: activeSessionId,
                    stage: .presentationReady
                )
            }

            while presentedMessageLimit < transcriptMessageLimit {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                presentedMessageLimit = SessionPresentationBatch.nextLimit(
                    current: presentedMessageLimit,
                    target: transcriptMessageLimit
                )
                transcriptScrollRequest &+= 1
                await Task.yield()
            }
        }
        .overlay {
            if let activeSessionId, !isSessionTransitioning {
                SessionOpenFirstFrameReporter {
                    sessionStore.finishActiveSessionOpenPerformance(
                        sessionID: activeSessionId
                    )
                }
            }
        }
        .sheet(item: elicitationBinding) { request in
            ACPElicitationFormView(request: request) { response in
                resolve(elicitation: request, response: response)
            }
            .interactiveDismissDisabled()
        }
    }

    private func transcript(
        messages: [PiChatMessage],
        hiddenMessageCount: Int
    ) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            ChatMessageRow(
                                message: message,
                                loadedToolOutputs: loadedToolOutputs,
                                loadingToolOutputIDs: loadingToolOutputIDs,
                                onLoadToolOutput: loadToolOutput
                            ) { approval, decision in
                                resolve(approval: approval, decision: decision)
                            }
                            .id(message.id)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(TranscriptLayout.tailID)
                            .background(
                                GeometryReader { tail in
                                    Color.clear.preference(
                                        key: TranscriptBottomPreferenceKey.self,
                                        value: tail.frame(
                                            in: .named(TranscriptLayout.coordinateSpace)
                                        ).maxY
                                    )
                                }
                            )
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background {
                        TranscriptUserScrollObserver(
                            topThreshold: TranscriptLayout.historyLoadThreshold,
                            bottomThreshold: TranscriptLayout.followThreshold,
                            hasEarlierMessages: hiddenMessageCount > 0,
                            onUserScroll: pauseTranscriptAutoFollow,
                            onReachTop: {
                                loadEarlierMessages(messages: messages, using: proxy)
                            },
                            onScrollPositionChange: updateTranscriptAutoFollowFromScrollView
                        )
                    }
                }
                .coordinateSpace(name: TranscriptLayout.coordinateSpace)
                .overlay(alignment: .bottom) {
                    if !isFollowingTranscriptTail {
                        Button {
                            scrollToTranscriptTail(using: proxy)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .background(.regularMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                        .shadow(color: AppPalette.subtleShadow, radius: 7, y: 2)
                        .padding(.bottom, 12)
                        .help(L10n.string("chat.scroll_to_latest"))
                        .accessibilityLabel(L10n.string("chat.scroll_to_latest"))
                        .transition(
                            accessibilityReduceMotion
                                ? .opacity
                                : .scale(scale: 0.92).combined(with: .opacity)
                        )
                    }
                }
                .animation(
                    accessibilityReduceMotion ? nil : .easeOut(duration: 0.16),
                    value: isFollowingTranscriptTail
                )
                .onPreferenceChange(TranscriptBottomPreferenceKey.self) { bottomY in
                    let updated = TranscriptScrollPresentation.updatedAutoFollowState(
                        current: TranscriptAutoFollowState(
                            isFollowingTail: isFollowingTranscriptTail,
                            isPaused: isTranscriptAutoFollowPaused
                        ),
                        bottomY: bottomY,
                        viewportHeight: viewport.size.height,
                        threshold: TranscriptLayout.followThreshold,
                        isAdjustingScroll: isAdjustingTranscriptScroll
                    )
                    isFollowingTranscriptTail = updated.isFollowingTail
                    isTranscriptAutoFollowPaused = updated.isPaused
                }
                .onChange(of: transcriptScrollToken(for: messages)) { _ in
                    guard isFollowingTranscriptTail, !isTranscriptAutoFollowPaused else { return }
                    scrollToTranscriptTail(using: proxy)
                }
                .onChange(of: transcriptScrollRequest) { _ in
                    scrollToTranscriptTail(using: proxy)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        scrollToTranscriptTail(using: proxy)
                    }
                }
            }
        }
    }

    private func scrollToTranscriptTail(using proxy: ScrollViewProxy) {
        isTranscriptAutoFollowPaused = false
        isFollowingTranscriptTail = true
        isAdjustingTranscriptScroll = true
        proxy.scrollTo(TranscriptLayout.tailID, anchor: .bottom)
        DispatchQueue.main.async {
            isAdjustingTranscriptScroll = false
        }
    }

    private func loadEarlierMessages(
        messages: [PiChatMessage],
        using proxy: ScrollViewProxy
    ) {
        guard let anchorID = messages.first?.id else { return }
        guard let record = presentedRecord else { return }
        if transcriptMessageLimit < record.transcript.count {
            transcriptMessageLimit += TranscriptWindow.batchSize
            presentedMessageLimit = transcriptMessageLimit
            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            return
        }
        guard record.hasEarlierMessages else { return }
        let sessionID = record.id
        Task {
            do {
                let loadedCount = try await sessionStore.loadEarlierMessages(
                    sessionId: sessionID
                )
                guard loadedCount > 0, activeSessionId == sessionID else { return }
                transcriptMessageLimit += TranscriptWindow.batchSize
                presentedMessageLimit = transcriptMessageLimit
                DispatchQueue.main.async {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            } catch {
                guard activeSessionId == sessionID else { return }
                actionError = String(describing: error)
            }
        }
    }

    private func pauseTranscriptAutoFollow() {
        guard !isTranscriptAutoFollowPaused else { return }
        isTranscriptAutoFollowPaused = true
        isFollowingTranscriptTail = false
    }

    private func updateTranscriptAutoFollowFromScrollView(isNearBottom: Bool) {
        isTranscriptAutoFollowPaused = !isNearBottom
        isFollowingTranscriptTail = isNearBottom
    }

    private var emptySession: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 8) {
                    Text(L10n.string("chat.welcome"))
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.86))

                    Text(mode == .work
                        ? L10n.string("chat.work_subtitle")
                        : L10n.string("chat.chat_subtitle"))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primary.opacity(0.48))
                }

                HStack(spacing: 12) {
                    ForEach(SessionSuggestion.defaults) { suggestion in
                        Button {
                            draft = suggestion.prompt
                        } label: {
                            SessionSuggestionCard(suggestion: suggestion)
                        }
                        .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 20))
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: 820)
            }
            .padding(.horizontal, 28)
            .padding(.top, 54)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private struct SessionTranscriptLoadingMask: View {
        @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

        @State private var shimmerProgress: CGFloat = -0.35

        var body: some View {
            ZStack {
                AppPalette.windowGradient

                skeletonContent
                    .overlay {
                        if !accessibilityReduceMotion {
                            GeometryReader { geometry in
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.primary.opacity(0.1),
                                        .clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: max(120, geometry.size.width * 0.24))
                                .offset(x: geometry.size.width * shimmerProgress)
                            }
                            .mask(skeletonContent)
                            .allowsHitTesting(false)
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            .clipped()
            .onAppear {
                guard !accessibilityReduceMotion else { return }
                shimmerProgress = -0.35
                withAnimation(
                    .linear(duration: 1.3)
                        .repeatForever(autoreverses: false)
                ) {
                    shimmerProgress = 1.35
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string("chat.session_loading"))
        }

        private var skeletonContent: some View {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Spacer(minLength: 80)
                    VStack(alignment: .trailing, spacing: 8) {
                        SkeletonLine(relativeWidth: 0.72, height: 13)
                        SkeletonLine(relativeWidth: 0.46, height: 10)
                    }
                    .frame(maxWidth: 340)
                }

                VStack(alignment: .leading, spacing: 9) {
                    SkeletonLine(relativeWidth: 0.9, height: 13)
                    SkeletonLine(relativeWidth: 0.78, height: 13)
                    SkeletonLine(relativeWidth: 0.58, height: 13)
                    SkeletonLine(relativeWidth: 0.12, height: 8)
                        .padding(.top, 2)
                }

                HStack(spacing: 9) {
                    Circle()
                        .fill(Color.primary.opacity(0.075))
                        .frame(width: 16, height: 16)
                    SkeletonLine(relativeWidth: 0.31, height: 11)
                }
                .frame(maxWidth: 330, alignment: .leading)

                HStack {
                    Spacer(minLength: 120)
                    VStack(alignment: .trailing, spacing: 8) {
                        SkeletonLine(relativeWidth: 0.84, height: 13)
                        SkeletonLine(relativeWidth: 0.54, height: 10)
                    }
                    .frame(maxWidth: 390)
                }

                VStack(alignment: .leading, spacing: 9) {
                    SkeletonLine(relativeWidth: 0.86, height: 13)
                    SkeletonLine(relativeWidth: 0.94, height: 13)
                    SkeletonLine(relativeWidth: 0.69, height: 13)
                    SkeletonLine(relativeWidth: 0.42, height: 13)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .blur(radius: 0.35)
        }
    }

    private struct SessionComposerLoadingMask: View {
        var body: some View {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("chat.session_loading"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(0.58))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppPalette.raisedSurface)
            .adaptiveCornerRadius(28)
            .accessibilityElement(children: .combine)
        }
    }

    private struct SkeletonLine: View {
        let relativeWidth: CGFloat
        let height: CGFloat

        var body: some View {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Color.primary.opacity(0.075))
                    .frame(width: geometry.size.width * relativeWidth, height: height)
            }
            .frame(height: height)
        }
    }

    private func send() {
        let text = SessionComposerState.submissionText(
            draft: draft,
            selectedCommand: selectedSlashCommand
        )
        guard
            SessionComposerState.primaryAction(
                draft: text,
                hasAttachments: !imageAttachments.isEmpty,
                isExecuting: isExecuting
            ) == .send,
            canSend
        else { return }

        let promptImages = imageAttachments.map(\.promptImage)
        draft = ""
        selectedSlashCommand = nil
        imageAttachments = []
        guard let sessionId = activeSessionId else { return }
        isTranscriptAutoFollowPaused = false
        isFollowingTranscriptTail = true
        transcriptScrollRequest &+= 1
        actionError = nil
        Task {
            do {
                try await sessionStore.submitPrompt(
                    sessionId: sessionId,
                    text: text,
                    images: promptImages
                )
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func handlePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        let sources = ComposerImagePasteboard.sources(from: pasteboard)
        guard !sources.isEmpty else { return false }
        guard !isProcessingImageAttachments else {
            actionError = L10n.string("chat.image.error.processing")
            return true
        }

        let processingID = UUID()
        let existingAttachments = imageAttachments
        imageProcessingID = processingID
        isProcessingImageAttachments = true
        actionError = nil

        Task { @MainActor in
            do {
                let attachments = try await Task.detached(priority: .userInitiated) {
                    try ComposerImageProcessor.process(
                        sources,
                        existingAttachments: existingAttachments
                    )
                }.value
                guard imageProcessingID == processingID else { return }
                imageAttachments.append(contentsOf: attachments)
                imageProcessingID = nil
                isProcessingImageAttachments = false
                actionError = nil
            } catch {
                guard imageProcessingID == processingID else { return }
                imageProcessingID = nil
                isProcessingImageAttachments = false
                actionError = (error as? ComposerImageAttachmentError)?.message
                    ?? L10n.string("chat.image.error.unsupported")
            }
        }
        return true
    }

    private func removeImageAttachment(_ id: UUID) {
        imageAttachments.removeAll { $0.id == id }
    }

    private func loadSlashCommands() async {
        guard mode == .work, let sessionId = activeSessionId else {
            slashCommands = []
            return
        }
        do {
            slashCommands = try await sessionStore.slashCommands(sessionId: sessionId)
            actionError = nil
        } catch {
            slashCommands = []
            actionError = String(describing: error)
        }
    }

    private func loadGitBranches() async {
        guard mode == .work, let project = selectedProject else {
            gitBranches = .unavailable
            return
        }
        let sessionId = activeSessionId
        do {
            let result = try await sessionStore.gitBranches(cwd: project.path)
            guard selectedProject?.id == project.id, activeSessionId == sessionId else { return }
            gitBranches = result
            guard
                result.available,
                let sessionId,
                activeRecord?.messages.isEmpty == true,
                activeRecord?.gitBranch == nil,
                let currentBranch = result.currentBranch,
                result.branches.contains(currentBranch)
            else { return }
            try? await sessionStore.setGitBranch(currentBranch, sessionId: sessionId)
        } catch {
            guard selectedProject?.id == project.id, activeSessionId == sessionId else { return }
            gitBranches = .unavailable
        }
    }

    private func selectGitBranch(_ branch: String) {
        guard let sessionId = activeSessionId, activeRecord?.messages.isEmpty == true else {
            return
        }
        actionError = nil
        Task {
            do {
                try await sessionStore.setGitBranch(branch, sessionId: sessionId)
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func selectModel(_ model: PiModelOption) {
        guard let sessionId = activeSessionId else { return }
        guard let hostModel = sessionStore.availableModels.first(where: {
            $0.provider == model.provider && $0.id == model.modelID
        }) else { return }
        actionError = nil
        Task {
            do {
                try await sessionStore.selectModel(hostModel, sessionId: sessionId)
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func toggleFastMode(_ model: PiModelOption) {
        guard model.supportsFastMode, let sessionId = activeSessionId else { return }
        guard let hostModel = sessionStore.availableModels.first(where: {
            $0.provider == model.provider && $0.id == model.modelID
        }) else { return }
        let isSelected = selectedModel == model
        let shouldEnable = !isSelected || activeRecord?.modelOptions.fastMode.enabled != true
        actionError = nil
        Task {
            do {
                if !isSelected {
                    try await sessionStore.selectModel(hostModel, sessionId: sessionId)
                }
                try await sessionStore.selectModelOption(
                    .fastMode,
                    enabled: shouldEnable,
                    sessionId: sessionId
                )
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func selectThinkingLevel(_ thinkingLevel: AgentHostThinkingLevel) {
        guard let sessionId = activeSessionId else { return }
        actionError = nil
        Task {
            do {
                try await sessionStore.selectThinkingLevel(
                    thinkingLevel,
                    sessionId: sessionId
                )
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func selectModelOption(
        _ option: AgentHostModelOption,
        enabled: Bool
    ) {
        guard let sessionId = activeSessionId else { return }
        actionError = nil
        Task {
            do {
                try await sessionStore.selectModelOption(
                    option,
                    enabled: enabled,
                    sessionId: sessionId
                )
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func selectConfigOption(
        _ option: AgentHostACPSetConfigOptionResult.ConfigOption,
        value: AgentHostACPSetConfigOptionResult.ConfigOption.Value
    ) {
        guard let sessionId = activeSessionId else { return }
        actionError = nil
        Task {
            do {
                try await sessionStore.selectConfigOption(
                    option,
                    value: value,
                    sessionId: sessionId
                )
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func selectSessionMode(_ modeId: String) {
        guard let sessionId = activeSessionId else { return }
        actionError = nil
        Task {
            do {
                try await sessionStore.selectSessionMode(modeId, sessionId: sessionId)
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func selectAccessMode(_ accessMode: AgentHostAccessMode) {
        guard let sessionId = activeSessionId else { return }
        actionError = nil
        Task {
            do {
                try await sessionStore.selectAccessMode(accessMode, sessionId: sessionId)
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func resolve(
        approval: AgentHostApprovalRequest,
        decision: AgentHostApprovalDecision
    ) {
        guard let sessionId = activeSessionId else { return }
        actionError = nil
        Task {
            do {
                try await sessionStore.resolveApproval(
                    sessionId: sessionId,
                    requestId: approval.id,
                    decision: decision
                )
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func resolve(
        elicitation: AgentHostACPElicitationRequest,
        response: AgentHostACPElicitationResponse
    ) {
        actionError = nil
        Task {
            do {
                try await sessionStore.resolveElicitation(
                    sessionId: elicitation.sessionId,
                    requestId: elicitation.id,
                    response: response
                )
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func loadToolOutput(_ tool: SessionToolRecord) {
        guard tool.outputTruncated,
              loadedToolOutputs[tool.id] == nil,
              loadingToolOutputIDs.insert(tool.id).inserted,
              let sessionId = activeSessionId else {
            return
        }
        Task {
            defer { loadingToolOutputIDs.remove(tool.id) }
            do {
                let output = try await sessionStore.toolOutput(
                    sessionId: sessionId,
                    toolCallId: tool.id
                )
                guard activeSessionId == sessionId else { return }
                loadedToolOutputs[tool.id] = output
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private func stopGeneration() {
        guard let sessionId = activeSessionId else { return }
        actionError = nil
        Task {
            do {
                try await sessionStore.abortSession(sessionId: sessionId)
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    private var activeSessionId: String? {
        switch mode {
        case .chat:
            return sessionStore.selectedChatSessionId
        case .work:
            guard let project = selectedProject else { return nil }
            return sessionStore.selectedWorkSessionIdByProjectPath[project.path]
        }
    }

    private var activeRecord: SessionRecord? {
        guard let sessionId = activeSessionId else { return nil }
        return sessionStore.records[sessionId]
    }

    private var elicitationBinding: Binding<AgentHostACPElicitationRequest?> {
        Binding(
            get: {
                activeRecord?.pendingElicitations.first
                    ?? sessionStore.pendingElicitations.first
            },
            set: { _ in }
        )
    }

    private var presentedRecord: SessionRecord? {
        guard let sessionId = presentedSessionID else { return nil }
        return sessionStore.records[sessionId]
    }

    private var gitBranchLoadID: String {
        "\(mode):\(selectedProject?.path ?? ""):\(activeSessionId ?? "")"
    }

    private var sessionPresentationID: String {
        "\(mode):\(activeSessionId ?? "unselected")"
    }

    private var isSessionTransitioning: Bool {
        isLoadingSession
            || isPreparingSessionPresentation
            || (activeSessionId != nil && readySessionPresentationID != sessionPresentationID)
    }

    private var messagePresentation: TranscriptWindow {
        guard let record = presentedRecord else {
            return TranscriptWindow(messages: [], hiddenCount: 0)
        }
        let streamingMessageID = record.activeTurnId.flatMap { turnId in
            let messageID = "turn:\(turnId):assistant"
            return record.transcript.last { message in
                message.role == .assistant
                    && (
                        message.id == messageID
                            || message.id.hasPrefix("\(messageID):")
                    )
            }?.id
        }
        let visibleWindow = TranscriptProjection.recentMessages(
            record.transcript,
            limit: min(transcriptMessageLimit, presentedMessageLimit)
        ) { message in
            let chatMessage = PiChatMessage(
                message: message,
                isStreaming: message.id == streamingMessageID && isExecuting
            )
            return chatMessage.isVisible ? chatMessage : nil
        }
        return TranscriptWindow(
            messages: AssistantTranscriptPresentation.groupAdjacentTools(
                in: visibleWindow.messages
            ),
            hiddenCount: visibleWindow.hiddenCount + (record.hasEarlierMessages ? 1 : 0)
        )
    }

    private func transcriptScrollToken(for messages: [PiChatMessage]) -> String {
        "\(messages.last?.id ?? ""):\(activeRecord?.lastSequence ?? 0)"
    }

    private var isExecuting: Bool {
        switch activeRecord?.runState {
        case .submitting, .running, .stopping: return true
        default: return false
        }
    }

    private var canSend: Bool {
        guard let model = activeRecord?.model else { return false }
        let baseCanSend = sessionStore.availableModels.contains {
            $0.provider == model.provider && $0.id == model.id
        }
        return SessionComposerState.canSend(
            baseCanSend: baseCanSend,
            hasAttachments: !imageAttachments.isEmpty,
            isProcessingAttachments: isProcessingImageAttachments,
            selectedModelSupportsImages: selectedModelSupportsImages
        )
    }

    private var selectedModelSupportsImages: Bool {
        activeRecord?.model?.supportsImages == true
    }

    private var availableModels: [PiModelOption] {
        guard activeRecord != nil else { return [] }
        return sessionStore.availableModels.map(PiModelOption.init(model:))
    }

    private var selectedModel: PiModelOption? {
        return activeRecord?.model.map(PiModelOption.init(model:))
    }

    private var selectedModelName: String {
        selectedModel?.displayName ?? L10n.string("chat.select_model")
    }

    private var errorMessage: String? {
        actionError ?? activeRecord?.errorMessage ?? hostError
    }
}

private enum TranscriptLayout {
    static let coordinateSpace = "transcript-scroll"
    static let tailID = "transcript-tail"
    static let historyLoadThreshold: CGFloat = 160
    static let followThreshold: CGFloat = 72
}

private struct SessionOpenFirstFrameReporter: View {
    let report: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear(perform: report)
    }
}

private struct TranscriptBottomPreferenceKey: PreferenceKey {
    static var defaultValue = CGFloat.infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TranscriptUserScrollObserver: NSViewRepresentable {
    let topThreshold: CGFloat
    let bottomThreshold: CGFloat
    let hasEarlierMessages: Bool
    let onUserScroll: () -> Void
    let onReachTop: () -> Void
    let onScrollPositionChange: (Bool) -> Void

    func makeNSView(context: Context) -> TranscriptUserScrollObserverView {
        let view = TranscriptUserScrollObserverView()
        view.topThreshold = topThreshold
        view.bottomThreshold = bottomThreshold
        view.hasEarlierMessages = hasEarlierMessages
        view.onUserScroll = onUserScroll
        view.onReachTop = onReachTop
        view.onScrollPositionChange = onScrollPositionChange
        return view
    }

    func updateNSView(_ nsView: TranscriptUserScrollObserverView, context: Context) {
        nsView.topThreshold = topThreshold
        nsView.bottomThreshold = bottomThreshold
        nsView.hasEarlierMessages = hasEarlierMessages
        nsView.onUserScroll = onUserScroll
        nsView.onReachTop = onReachTop
        nsView.onScrollPositionChange = onScrollPositionChange
    }
}

private final class TranscriptUserScrollObserverView: NSView {
    var topThreshold: CGFloat = 0
    var bottomThreshold: CGFloat = 0
    var hasEarlierMessages = false
    var onUserScroll: () -> Void = {}
    var onReachTop: () -> Void = {}
    var onScrollPositionChange: (Bool) -> Void = { _ in }

    private weak var observedScrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var isUserScrolling = false
    private var historyLoadTrigger = TranscriptHistoryLoadTrigger()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeEnclosingScrollViewOnNextRunLoop()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeEnclosingScrollViewOnNextRunLoop()
    }

    deinit {
        removeObserver()
    }

    private func observeEnclosingScrollViewOnNextRunLoop() {
        DispatchQueue.main.async { [weak self] in
            self?.observeEnclosingScrollView()
        }
    }

    private func observeEnclosingScrollView() {
        let scrollView = enclosingScrollView
        guard observedScrollView !== scrollView else { return }
        removeObserver()
        guard let scrollView else { return }
        observedScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isUserScrolling = true
            self?.onUserScroll()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.reportScrollPosition()
            self?.isUserScrolling = false
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.reportScrollPosition()
        })
        reportScrollPosition()
    }

    private func reportScrollPosition() {
        guard let scrollView = observedScrollView,
              let documentView = scrollView.documentView else { return }
        let visibleRect = scrollView.contentView.bounds
        let documentBounds = documentView.bounds
        let scrollableDistance = max(0, documentBounds.height - visibleRect.height)
        let scrollPosition = CGFloat(scrollView.verticalScroller?.floatValue ?? 1)
        if historyLoadTrigger.update(
            distanceFromTop: scrollPosition * scrollableDistance,
            isUserScrolling: isUserScrolling,
            hasEarlierMessages: hasEarlierMessages,
            threshold: topThreshold
        ) {
            onReachTop()
        }
        let isNearBottom = TranscriptScrollPresentation.isNearBottom(
            scrollPosition: scrollPosition,
            scrollableDistance: scrollableDistance,
            threshold: bottomThreshold
        )
        if isUserScrolling || isNearBottom {
            onScrollPositionChange(isNearBottom)
        }
    }

    private func removeObserver() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        isUserScrolling = false
        observedScrollView = nil
    }
}

private struct SessionComposer: View {
    let sessionIdentity: String
    let mode: SidebarTab
    let projects: [PiProject]
    @Binding var selectedProject: PiProject?
    @Binding var draft: String
    @Binding var selectedSlashCommand: AgentHostSlashCommand?
    let slashCommands: [AgentHostSlashCommand]
    let promptHistory: [String]
    let imageAttachments: [ComposerImageAttachment]
    let isProcessingImageAttachments: Bool
    let selectedModelSupportsImages: Bool
    let isExecuting: Bool
    let canSend: Bool
    let availableModels: [PiModelOption]
    let selectedModel: PiModelOption?
    let selectedModelName: String
    let contextUsage: AgentHostContextUsage?
    let plan: [AgentHostACPPlanEntry]
    let extensionStatuses: [String: String]
    let extensionWidgets: [String: AgentHostExtensionWidget]
    let cost: AgentHostACPSessionCost?
    let selectedThinkingLevel: AgentHostThinkingLevel?
    let availableThinkingLevels: [AgentHostThinkingLevel]
    let modelOptions: AgentHostModelOptions
    let genericConfigOptions: [AgentHostACPSetConfigOptionResult.ConfigOption]
    let genericModeState: AgentHostACPSessionModeState?
    let selectedAccessMode: AgentHostAccessMode?
    let gitBranches: [String]
    let isGitAvailable: Bool
    let selectedGitBranch: String?
    let canSelectGitBranch: Bool
    let onAddFolder: () -> Void
    let onSelectProject: (PiProject) -> Void
    let onSelectGitBranch: (String) -> Void
    let onSelectModel: (PiModelOption) -> Void
    let onToggleFastMode: (PiModelOption) -> Void
    let onSelectThinkingLevel: (AgentHostThinkingLevel) -> Void
    let onSelectModelOption: (AgentHostModelOption, Bool) -> Void
    let onSelectConfigOption: (
        AgentHostACPSetConfigOptionResult.ConfigOption,
        AgentHostACPSetConfigOptionResult.ConfigOption.Value
    ) -> Void
    let onSelectSessionMode: (String) -> Void
    let onSelectAccessMode: (AgentHostAccessMode) -> Void
    let onPasteboard: (NSPasteboard) -> Bool
    let onRemoveImage: (UUID) -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    private let outerRadius: CGFloat = 28
    private let innerRadius: CGFloat = 27

    @State private var editorHeight = SessionComposerState.minimumEditorHeight
    @State private var isComposerHovering = false
    @State private var isProjectPickerPresented = false
    @State private var isGitBranchPickerPresented = false
    @State private var gitBranchSearchQuery = ""
    @FocusState private var isGitBranchSearchFocused: Bool
    @State private var isModelPickerPresented = false
    @State private var modelSearchQuery = ""
    @FocusState private var isModelSearchFocused: Bool
    @State private var isThinkingPickerPresented = false
    @State private var thinkingSliderValue = 0.0
    @State private var isAccessPickerPresented = false
    @State private var highlightedSlashCommandIndex = 0
    @State private var isSlashCommandPanelDismissed = false
    @State private var editorFocusRequest = 0
    @State private var promptHistoryNavigation = SessionComposerPromptHistoryNavigation()
    @State private var previewedImageAttachment: ComposerImageAttachment?
    @State private var isInputMethodComposing = false
    @State private var isActivityExpanded = false

    var body: some View {
        VStack(spacing: 9) {
            SessionActivityPanel(
                plan: plan,
                statuses: extensionStatuses,
                widgets: extensionWidgets,
                isExpanded: $isActivityExpanded
            )
            .frame(maxWidth: .infinity)

            if isSlashCommandPanelPresented {
                slashCommandPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            composerSurface
        }
        .animation(.easeOut(duration: 0.16), value: isSlashCommandPanelPresented)
        .onChange(of: draft) { _ in
            highlightedSlashCommandIndex = 0
            isSlashCommandPanelDismissed = false
        }
        .onChange(of: slashCommands.map(\.id)) { _ in
            highlightedSlashCommandIndex = 0
        }
        .onChange(of: sessionIdentity) { _ in
            isProjectPickerPresented = false
            isGitBranchPickerPresented = false
            gitBranchSearchQuery = ""
            isGitBranchSearchFocused = false
            isModelPickerPresented = false
            modelSearchQuery = ""
            isModelSearchFocused = false
            isThinkingPickerPresented = false
            isAccessPickerPresented = false
            highlightedSlashCommandIndex = 0
            isSlashCommandPanelDismissed = false
            promptHistoryNavigation = SessionComposerPromptHistoryNavigation()
            previewedImageAttachment = nil
            isInputMethodComposing = false
            isActivityExpanded = false
        }
        .sheet(item: $previewedImageAttachment) { attachment in
            ComposerImagePreview(data: attachment.data)
        }
        // Lets outside clicks (transcript/sidebar/title bar) resign the caret.
        .background {
            ComposerSurfaceMarker()
        }
    }

    @ViewBuilder
    private var composerSurface: some View {
        Group {
            if mode.showsProjectSelection {
                VStack(spacing: 0) {
                    projectBar
                    editor
                        .background(AppPalette.raisedSurface)
                        .adaptiveCornerRadius(innerRadius)
                }
                .background(Color.primary.opacity(0.045))
                .adaptiveCornerRadius(outerRadius)
                .overlay(
                    adaptiveRoundedShape(cornerRadius: outerRadius)
                        .stroke(composerBorderColor, lineWidth: composerBorderWidth)
                )
                .shadow(color: AppPalette.raisedShadow, radius: 16, y: 5)
            } else {
                editor
                    .background(AppPalette.raisedSurface)
                    .adaptiveCornerRadius(outerRadius)
                    .overlay(
                        adaptiveRoundedShape(cornerRadius: outerRadius)
                            .stroke(composerBorderColor, lineWidth: composerBorderWidth)
                    )
                    .shadow(color: AppPalette.raisedShadow, radius: 16, y: 5)
            }
        }
        .onHover { isComposerHovering = $0 }
    }

    private var slashCommandQuery: String? {
        guard selectedSlashCommand == nil, !isSlashCommandPanelDismissed else { return nil }
        return SessionComposerState.slashQuery(in: draft, mode: mode)
    }

    private var filteredSlashCommands: [AgentHostSlashCommand] {
        guard let slashCommandQuery else { return [] }
        return SessionComposerState.filteredSlashCommands(
            slashCommands,
            query: slashCommandQuery
        )
    }

    private var isSlashCommandPanelPresented: Bool {
        slashCommandQuery != nil
    }

    private var slashCommandPanelHeight: CGFloat {
        guard !filteredSlashCommands.isEmpty else { return 58 }
        return CGFloat(min(filteredSlashCommands.count, 5) * 44 + 14)
    }

    private var slashCommandPanel: some View {
        Group {
            if filteredSlashCommands.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(L10n.string("chat.slash.no_matches"))
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.48))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredSlashCommands.indices, id: \.self) { index in
                            slashCommandRow(filteredSlashCommands[index], index: index)
                        }
                    }
                    .padding(7)
                }
            }
        }
        .frame(height: slashCommandPanelHeight)
        .background(AppPalette.raisedSurface)
        .adaptiveCornerRadius(18)
        .overlay(
            adaptiveRoundedShape(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: AppPalette.raisedShadow, radius: 14, y: 5)
        .accessibilityIdentifier("slash-command-menu")
    }

    private func slashCommandRow(
        _ command: AgentHostSlashCommand,
        index: Int
    ) -> some View {
        Button {
            selectSlashCommand(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.source.composerIcon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)

                Text(command.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let description = command.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.46))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(command.source.composerKindTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.38))
                    .fixedSize()
            }
            .foregroundStyle(Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        }
        .buttonStyle(
            RoundedInteractionButtonStyle(
                cornerRadius: 10,
                isSelected: highlightedSlashCommandIndex == index
            )
        )
        .onHover { hovering in
            if hovering { highlightedSlashCommandIndex = index }
        }
        .accessibilityLabel(
            "\(command.displayName), \(command.source.composerKindTitle)"
        )
        .accessibilityIdentifier("slash-command-\(command.id)")
    }

    private func selectSlashCommand(_ command: AgentHostSlashCommand) {
        draft = SessionComposerState.draftAfterSelectingSlashCommand(from: draft)
        selectedSlashCommand = command
        isSlashCommandPanelDismissed = true
        editorFocusRequest += 1
    }

    private func removeSelectedSlashCommand() {
        guard selectedSlashCommand != nil else { return }
        selectedSlashCommand = nil
        draft = draft.isEmpty ? "/" : "/ \(draft)"
        editorFocusRequest += 1
    }

    private func handleEditorCommand(_ command: SessionComposerEditorCommand) -> Bool {
        switch command {
        case .confirmSuggestion:
            guard isSlashCommandPanelPresented,
                  filteredSlashCommands.indices.contains(highlightedSlashCommandIndex)
            else { return false }
            selectSlashCommand(filteredSlashCommands[highlightedSlashCommandIndex])
            return true
        case .selectPreviousSuggestion:
            guard isSlashCommandPanelPresented, !filteredSlashCommands.isEmpty else {
                return false
            }
            highlightedSlashCommandIndex = (
                highlightedSlashCommandIndex - 1 + filteredSlashCommands.count
            ) % filteredSlashCommands.count
            return true
        case .selectNextSuggestion:
            guard isSlashCommandPanelPresented, !filteredSlashCommands.isEmpty else {
                return false
            }
            highlightedSlashCommandIndex = (
                highlightedSlashCommandIndex + 1
            ) % filteredSlashCommands.count
            return true
        case .dismissSuggestions:
            guard isSlashCommandPanelPresented else { return false }
            isSlashCommandPanelDismissed = true
            return true
        case .deleteSelectedCommand:
            guard selectedSlashCommand != nil else { return false }
            removeSelectedSlashCommand()
            return true
        case .recallPreviousPrompt:
            let currentDraft = SessionComposerState.submissionText(
                draft: draft,
                selectedCommand: selectedSlashCommand
            )
            guard let prompt = promptHistoryNavigation.previous(
                in: promptHistory,
                currentDraft: currentDraft
            ) else { return false }
            applyRecalledPrompt(prompt)
            return true
        case .recallNextPrompt:
            guard let prompt = promptHistoryNavigation.next(in: promptHistory) else {
                return false
            }
            applyRecalledPrompt(prompt)
            return true
        }
    }

    private func applyRecalledPrompt(_ prompt: String) {
        let recalled = SessionComposerState.recalledPrompt(prompt, commands: slashCommands)
        selectedSlashCommand = recalled.selectedCommand
        draft = recalled.draft
    }

    private func submitPrompt() {
        promptHistoryNavigation.reset()
        onSend()
    }

    private var projectBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 16) {
                projectPicker

                if selectedProject != nil {
                    gitBranchControl
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: geometry.size.width, height: 38)
            .popover(
                isPresented: $isProjectPickerPresented,
                attachmentAnchor: .point(
                    UnitPoint(
                        x: SessionComposerState.projectPickerPopoverAnchorX(
                            composerWidth: geometry.size.width
                        ),
                        y: 0
                    )
                ),
                arrowEdge: .top
            ) {
                projectPickerContent
            }
        }
        .frame(height: 38)
    }

    @ViewBuilder
    private var gitBranchControl: some View {
        if canSelectGitBranch {
            Button {
                gitBranchSearchQuery = ""
                isGitBranchPickerPresented.toggle()
            } label: {
                gitBranchLabel(opacity: isGitBranchPickerEnabled ? 0.82 : 0.28)
            }
            .buttonStyle(
                RoundedInteractionButtonStyle(
                    cornerRadius: 9,
                    isSelected: isGitBranchPickerPresented
                )
            )
            .disabled(!isGitBranchPickerEnabled)
            .accessibilityLabel(L10n.string("chat.select_branch"))
            .accessibilityIdentifier("git-branch-picker")
            .popover(isPresented: $isGitBranchPickerPresented, arrowEdge: .top) {
                gitBranchPickerContent
            }
        } else {
            gitBranchLabel(opacity: selectedGitBranch == nil ? 0.28 : 0.72)
                .help(L10n.string("chat.branch_read_only"))
                .accessibilityLabel(selectedGitBranch ?? L10n.string("chat.select_branch"))
                .accessibilityIdentifier("git-branch-picker")
        }
    }

    private func gitBranchLabel(opacity: Double) -> some View {
        HStack(spacing: 7) {
            GitBranchIcon()
            Text(selectedGitBranch ?? L10n.string("chat.select_branch"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 14))
        .foregroundStyle(Color.primary)
        .opacity(opacity)
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(
            adaptiveRoundedShape(cornerRadius: 9)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var gitBranchPickerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.primary.opacity(0.42))
                TextField(L10n.string("chat.search_branches"), text: $gitBranchSearchQuery)
                    .textFieldStyle(.plain)
                    .focused($isGitBranchSearchFocused)
                    .accessibilityIdentifier("branch-picker-search")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()

            ScrollView(.vertical) {
                if filteredGitBranches.isEmpty {
                    Text(L10n.string("chat.no_branches"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.46))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .padding(6)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredGitBranches, id: \.self) { branch in
                            gitBranchPickerRow(branch)
                        }
                    }
                    .padding(6)
                }
            }
            .frame(height: gitBranchPickerListHeight)
            .accessibilityIdentifier("branch-picker-scroll-view")
        }
        .frame(width: 310)
        .onAppear {
            DispatchQueue.main.async {
                isGitBranchSearchFocused = true
            }
        }
    }

    private func gitBranchPickerRow(_ branch: String) -> some View {
        Button {
            onSelectGitBranch(branch)
            isGitBranchPickerPresented = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(branch == selectedGitBranch ? 1 : 0)
                    .frame(width: 14)
                GitBranchIcon()
                    .opacity(0.68)
                Text(branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.primary.opacity(0.84))
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
        .buttonStyle(
            RoundedInteractionButtonStyle(
                cornerRadius: 8,
                isSelected: branch == selectedGitBranch
            )
        )
        .accessibilityIdentifier("git-branch-\(branch)")
    }

    private var filteredGitBranches: [String] {
        SessionComposerState.filteredGitBranches(
            gitBranches,
            query: gitBranchSearchQuery
        )
    }

    private var gitBranchPickerListHeight: CGFloat {
        let rowCount = max(
            SessionComposerState.visibleGitBranchRowCount(
                resultCount: filteredGitBranches.count
            ),
            1
        )
        return CGFloat(rowCount * 42 + 10)
    }

    private var isGitBranchPickerEnabled: Bool {
        isGitAvailable && !gitBranches.isEmpty
    }

    private var projectPicker: some View {
        Button {
            isProjectPickerPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(selectedProject?.name ?? L10n.string("chat.select_project"))
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.42))
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.primary.opacity(selectedProject == nil ? 0.48 : 0.82))
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
        .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 9))
        .fixedSize()
        .accessibilityLabel(L10n.string("chat.select_project"))
    }

    private var projectPickerContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(projects) { project in
                Button {
                    onSelectProject(project)
                    isProjectPickerPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Label(project.name, systemImage: "folder")
                            .lineLimit(1)
                        Spacer(minLength: 16)
                        if selectedProject?.id == project.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                }
                .buttonStyle(
                    RoundedInteractionButtonStyle(
                        cornerRadius: 8,
                        isSelected: selectedProject?.id == project.id
                    )
                )
            }

            if !projects.isEmpty {
                Divider()
                    .padding(.vertical, 4)
            }

            Button {
                isProjectPickerPresented = false
                DispatchQueue.main.async {
                    onAddFolder()
                }
            } label: {
                Label(L10n.string("chat.add_project"), systemImage: "plus")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
            .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 8))
        }
        .padding(8)
        .frame(width: SessionComposerState.projectPickerPopoverWidth)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !imageAttachments.isEmpty || isProcessingImageAttachments {
                imageAttachmentStrip
            }

            if !imageAttachments.isEmpty, !selectedModelSupportsImages {
                Label(
                    L10n.string("chat.image.model_unsupported"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("image-model-unsupported")
            }

            ZStack(alignment: .topLeading) {
                GrowingTextEditor(
                    text: $draft,
                    height: $editorHeight,
                    leadingExclusionWidth: selectedSlashCommandTokenWidth,
                    focusRequest: editorFocusRequest,
                    onEditorCommand: handleEditorCommand,
                    onPasteboard: onPasteboard,
                    onCompositionChange: { isInputMethodComposing = $0 },
                    onSubmit: submitPrompt
                )
                .frame(height: editorHeight)
                .accessibilityIdentifier("session-composer-input")

                selectedSlashCommandToken

                if draft.isEmpty, selectedSlashCommand == nil, !isInputMethodComposing {
                    Text(L10n.string("chat.input_placeholder"))
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .padding(.leading, 1)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)

            HStack(spacing: 10) {
                if mode == .work, let selectedAccessMode {
                    accessModeMenu(selectedAccessMode)
                }

                Spacer(minLength: 0)
                if contextUsage != nil || cost != nil {
                    ContextUsageIndicator(usage: contextUsage, cost: cost)
                }
                if genericModeState != nil || !genericConfigOptions.isEmpty {
                    genericConfigMenu
                }
                HStack(spacing: 4) {
                    modelPicker

                    if let selectedThinkingLevel {
                        thinkingLevelMenu(selectedThinkingLevel)
                    }
                }

                primaryActionButton
            }
            .frame(height: 42)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var imageAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(imageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Button {
                            previewedImageAttachment = attachment
                        } label: {
                            Group {
                                if let preview = NSImage(data: attachment.data) {
                                    Image(nsImage: preview)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "photo")
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                            .frame(width: 54, height: 54)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("chat.image.preview"))
                        .accessibilityLabel(L10n.string("chat.image.preview"))
                        .accessibilityIdentifier("preview-image-\(attachment.id.uuidString)")

                        Button {
                            onRemoveImage(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.primary.opacity(0.8))
                                .frame(width: 18, height: 18)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help(L10n.string("chat.image.remove"))
                        .accessibilityLabel(L10n.string("chat.image.remove"))
                        .accessibilityIdentifier("remove-image-\(attachment.id.uuidString)")
                    }
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                }

                if isProcessingImageAttachments {
                    VStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string("chat.image.processing"))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(width: 64, height: 54)
                    .accessibilityIdentifier("processing-image-attachments")
                }
            }
        }
        .frame(height: 64)
    }

    private var selectedSlashCommandTokenWidth: CGFloat {
        guard let command = selectedSlashCommand else { return 0 }
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let textWidth = (command.displayName as NSString).size(
            withAttributes: [.font: font]
        ).width
        return ceil(17 + 5 + textWidth)
    }

    @ViewBuilder
    private var selectedSlashCommandToken: some View {
        if let command = selectedSlashCommand {
            Button {
                removeSelectedSlashCommand()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: command.source.composerIcon)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 17)
                    Text(command.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.accentColor)
                .frame(height: 18)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .help(L10n.format("chat.slash.remove", command.displayName))
            .accessibilityLabel(L10n.format("chat.slash.remove", command.displayName))
        }
    }

    private var modelPicker: some View {
        Button {
            modelSearchQuery = ""
            isModelPickerPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selectedModelName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.42))
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.primary.opacity(0.82))
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
        .buttonStyle(
            RoundedInteractionButtonStyle(
                cornerRadius: 9,
                isSelected: isModelPickerPresented
            )
        )
        .fixedSize()
        .disabled(availableModels.isEmpty)
        .accessibilityLabel(L10n.string("chat.select_model"))
        .popover(isPresented: $isModelPickerPresented, arrowEdge: .top) {
            modelPickerContent
        }
    }

    private var genericConfigMenu: some View {
        Menu {
            if let genericModeState {
                Section(L10n.string("chat.agent_mode")) {
                    ForEach(genericModeState.availableModes) { mode in
                        Button {
                            onSelectSessionMode(mode.id)
                        } label: {
                            HStack {
                                Text(mode.name)
                                if mode.id == genericModeState.currentModeId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .help(mode.description ?? mode.name)
                    }
                }
            }

            ForEach(genericConfigOptions, id: \.id) { option in
                genericConfigControl(option)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.string("chat.agent_settings"))
        .accessibilityLabel(L10n.string("chat.agent_settings"))
        .accessibilityIdentifier("agent-config-menu")
    }

    @ViewBuilder
    private func genericConfigControl(
        _ option: AgentHostACPSetConfigOptionResult.ConfigOption
    ) -> some View {
        switch option.currentValue {
        case .boolean(let enabled):
            Toggle(
                option.name,
                isOn: Binding(
                    get: { enabled },
                    set: { onSelectConfigOption(option, .boolean($0)) }
                )
            )
        case .string(let currentValue):
            Menu(option.name) {
                ForEach(option.options ?? [], id: \.value) { choice in
                    Button {
                        onSelectConfigOption(option, .string(choice.value))
                    } label: {
                        HStack {
                            Text(choice.name)
                            if choice.value == currentValue {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }

    private var modelPickerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.primary.opacity(0.42))
                TextField(L10n.string("chat.search_models"), text: $modelSearchQuery)
                    .textFieldStyle(.plain)
                    .focused($isModelSearchFocused)
                    .accessibilityIdentifier("model-picker-search")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .padding(6)

            ScrollView(.vertical) {
                if filteredModels.isEmpty {
                    Text(L10n.string("chat.no_models"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.46))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .padding(6)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredModels) { model in
                            modelPickerRow(model)
                        }
                    }
                    .padding(6)
                }
            }
            .frame(height: modelPickerListHeight)
            .accessibilityIdentifier("model-picker-scroll-view")
        }
        .frame(width: 260)
        .onAppear {
            DispatchQueue.main.async {
                isModelSearchFocused = true
            }
        }
    }

    private func modelPickerRow(_ model: PiModelOption) -> some View {
        HStack(spacing: 4) {
            Button {
                onSelectModel(model)
                isModelPickerPresented = false
            } label: {
                HStack(spacing: 8) {
                    ModelProviderIcon(model: model)
                    Text(model.displayName)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(model == selectedModel ? 1 : 0)
                        .frame(width: 14)
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.84))
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            }
            .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 7))

            fastModeButton(for: model)
        }
        .frame(maxWidth: .infinity)
    }

    private func fastModeButton(for model: PiModelOption) -> some View {
        let isEnabled = model == selectedModel && modelOptions.fastMode.enabled

        return Button {
            onToggleFastMode(model)
        } label: {
            FastModeCapsuleSwitch(
                isOn: isEnabled,
                isAvailable: model.supportsFastMode
            )
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .opacity(model.supportsFastMode ? 1 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!model.supportsFastMode)
        .help(model.supportsFastMode
            ? L10n.string("chat.fast_mode")
            : L10n.string("chat.fast_unsupported"))
        .accessibilityLabel(L10n.format("chat.fast_accessibility", model.displayName))
        .accessibilityValue(
            isEnabled
                ? L10n.string("chat.enabled")
                : (model.supportsFastMode
                    ? L10n.string("chat.disabled")
                    : L10n.string("chat.unsupported"))
        )
        .accessibilityIdentifier("fast-mode-\(model.id)")
    }

    private var filteredModels: [PiModelOption] {
        SessionComposerState.filteredModels(
            availableModels,
            query: modelSearchQuery
        )
    }

    private var modelPickerListHeight: CGFloat {
        let rowCount = max(
            SessionComposerState.visibleModelRowCount(
                resultCount: filteredModels.count
            ),
            1
        )
        return CGFloat(rowCount * 36 + 10)
    }

    private func thinkingLevelMenu(
        _ selectedThinkingLevel: AgentHostThinkingLevel
    ) -> some View {
        Button {
            thinkingSliderValue = Double(
                availableThinkingLevels.firstIndex(of: selectedThinkingLevel) ?? 0
            )
            isThinkingPickerPresented.toggle()
        } label: {
            Text(selectedThinkingLevel.composerTitle)
                .font(.system(size: 14))
                .foregroundStyle(Color.primary.opacity(0.72))
                .padding(.horizontal, 10)
                .frame(height: 32)
        }
        .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 9))
        .fixedSize()
        .help(L10n.format("chat.thinking_help", selectedThinkingLevel.composerTitle))
        .accessibilityLabel(L10n.format("chat.thinking_help", selectedThinkingLevel.composerTitle))
        .accessibilityIdentifier("session-thinking-level")
        .popover(isPresented: $isThinkingPickerPresented, arrowEdge: .bottom) {
            thinkingLevelPickerContent(selectedThinkingLevel)
        }
    }

    private func thinkingLevelPickerContent(
        _ selectedThinkingLevel: AgentHostThinkingLevel
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if availableThinkingLevels.count > 1 {
                HStack(spacing: 5) {
                    Text(L10n.string("chat.effort"))
                        .foregroundStyle(Color.primary.opacity(0.48))
                    Text(pendingThinkingLevel?.composerTitle ?? selectedThinkingLevel.composerTitle)
                        .foregroundStyle(Color.primary.opacity(0.82))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 14, weight: .medium))

                HStack {
                    Text(L10n.string("chat.faster"))
                    Spacer(minLength: 0)
                    Text(L10n.string("chat.smarter"))
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.48))

                ZStack {
                    HStack(spacing: 0) {
                        ForEach(availableThinkingLevels.indices, id: \.self) { index in
                            Circle()
                                .fill(Color.primary.opacity(0.25))
                                .frame(width: 4, height: 4)
                            if index < availableThinkingLevels.count - 1 {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)

                    Slider(
                        value: $thinkingSliderValue,
                        in: 0...Double(max(availableThinkingLevels.count - 1, 1)),
                        step: 1,
                        onEditingChanged: { isEditing in
                            guard !isEditing,
                                  let level = pendingThinkingLevel,
                                  level != selectedThinkingLevel else { return }
                            onSelectThinkingLevel(level)
                        }
                    )
                    .tint(Color.primary.opacity(0.20))
                    .accessibilityLabel(L10n.string("chat.thinking_accessibility"))
                    .accessibilityValue(
                        pendingThinkingLevel?.composerTitle ?? selectedThinkingLevel.composerTitle
                    )
                    .accessibilityIdentifier("thinking-level-slider")
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(
                    adaptiveRoundedShape(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.07))
                )

                Divider()
            }

            modelOptionToggle(
                Text(L10n.string("chat.one_million_context")),
                option: .oneMillionContext,
                state: modelOptions.oneMillionContext,
                accessibilityIdentifier: "one-million-context-toggle"
            )
        }
        .padding(16)
        .frame(width: 300)
    }

    private func modelOptionToggle(
        _ title: Text,
        option: AgentHostModelOption,
        state: AgentHostModelOptionState,
        accessibilityIdentifier: String
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: { state.enabled },
                set: { onSelectModelOption(option, $0) }
            )
        ) {
            title
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(state.supported ? 0.82 : 0.34))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!state.supported)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var pendingThinkingLevel: AgentHostThinkingLevel? {
        SessionComposerState.thinkingLevel(
            forSliderValue: thinkingSliderValue,
            availableLevels: availableThinkingLevels
        )
    }

    private func accessModeMenu(_ selectedAccessMode: AgentHostAccessMode) -> some View {
        Button {
            isAccessPickerPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedAccessMode.composerIcon)
                    .font(.system(size: 13))
                Text(selectedAccessMode.composerTitle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.42))
            }
            .font(.system(size: 14))
            .foregroundStyle(
                selectedAccessMode == .full
                    ? Color.orange
                    : Color.primary.opacity(0.82)
            )
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
        .buttonStyle(
            RoundedInteractionButtonStyle(
                cornerRadius: 9,
                isSelected: isAccessPickerPresented
            )
        )
        .fixedSize()
        .help(selectedAccessMode.composerDescription)
        .accessibilityLabel(L10n.format("chat.access_help", selectedAccessMode.composerTitle))
        .accessibilityIdentifier("session-access-mode")
        .popover(isPresented: $isAccessPickerPresented, arrowEdge: .top) {
            accessModePickerContent(selectedAccessMode)
        }
    }

    private func accessModePickerContent(
        _ selectedAccessMode: AgentHostAccessMode
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(AgentHostAccessMode.workChoices) { accessMode in
                Button {
                    onSelectAccessMode(accessMode)
                    isAccessPickerPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: accessMode.composerIcon)
                            .frame(width: 16)
                        Text(accessMode.composerTitle)
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(accessMode == selectedAccessMode ? 1 : 0)
                            .frame(width: 14)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(
                        accessMode == .full
                            ? Color.orange
                            : Color.primary.opacity(0.84)
                    )
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }
                .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 7))
                .help(accessMode.composerDescription)
            }
        }
        .padding(5)
        .frame(width: 184)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch primaryAction {
        case .none:
            primaryButton(
                icon: "arrow.up",
                accessibilityLabel: L10n.string("chat.send"),
                isActive: false,
                action: submitPrompt
            )
                .disabled(true)
                .accessibilityIdentifier("send-session")
        case .send:
            primaryButton(
                icon: "arrow.up",
                accessibilityLabel: L10n.string("chat.send"),
                isActive: canSend,
                action: submitPrompt
            )
                .disabled(!canSend)
                .accessibilityIdentifier("send-session")
        case .stop:
            primaryButton(
                icon: "stop.fill",
                accessibilityLabel: L10n.string("chat.stop"),
                isActive: true,
                action: onStop
            )
                .accessibilityIdentifier("stop-session")
        }
    }

    private var primaryAction: SessionComposerPrimaryAction {
        SessionComposerState.primaryAction(
            draft: SessionComposerState.submissionText(
                draft: draft,
                selectedCommand: selectedSlashCommand
            ),
            hasAttachments: !imageAttachments.isEmpty,
            isExecuting: isExecuting
        )
    }

    private func primaryButton(
        icon: String,
        accessibilityLabel: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: icon == "stop.fill" ? 10 : 15, weight: .medium))
                .foregroundStyle(
                    isActive ? AppPalette.raisedSurface : Color.secondary.opacity(0.9)
                )
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(
                        isActive ? Color.primary.opacity(0.92) : Color.primary.opacity(0.16)
                    )
                )
        }
        .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 17))
        .accessibilityLabel(accessibilityLabel)
    }

    private var composerBorderColor: Color {
        Color.primary.opacity(
            SessionComposerState.borderOpacity(isHovering: isComposerHovering)
        )
    }

    private var composerBorderWidth: CGFloat {
        SessionComposerState.borderWidth
    }
}

struct SessionActivityPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let plan: [AgentHostACPPlanEntry]
    let statuses: [String: String]
    let widgets: [String: AgentHostExtensionWidget]
    @Binding var isExpanded: Bool

    var body: some View {
        let activity = SessionActivityPresentation(plan: plan, statuses: statuses, widgets: widgets)
        let expanded = isExpanded && activity.canExpand
        if activity.hasContent {
            VStack(spacing: 0) {
                if activity.canExpand {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        header(activity, expanded: expanded)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string(expanded ? "chat.activity.collapse" : "chat.activity.expand"))
                    .accessibilityValue(activity.summary)
                    .accessibilityIdentifier("session-activity-toggle")
                } else {
                    header(activity, expanded: false)
                }

                if expanded {
                    Divider().padding(.horizontal, 12)
                    ViewThatFits(in: .vertical) {
                        details(activity).padding(12)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView(.vertical) {
                            details(activity)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: 220)
                    .accessibilityIdentifier("session-activity-details")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.035))
            .adaptiveCornerRadius(expanded ? 12 : 14)
            .frame(maxWidth: expanded ? 440 : 320)
            .accessibilityIdentifier("session-activity-panel")
        }
    }

    private func header(_ activity: SessionActivityPresentation, expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet")
                .foregroundStyle(.secondary)
            Text(verbatim: expanded ? L10n.string("chat.activity.title") : activity.summary)
                .font(.system(size: 12, weight: expanded ? .medium : .regular))
                .lineLimit(1)
                .frame(maxWidth: activity.canExpand ? .infinity : nil, alignment: .leading)
            if !plan.isEmpty {
                Text("\(plan.filter { $0.status == .completed }.count)/\(plan.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if activity.items.count > 1 {
                Text("\(activity.items.count)").foregroundStyle(.secondary)
            }
            if activity.canExpand {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .help(activity.summary)
    }

    private func details(_ activity: SessionActivityPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !plan.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("chat.session_plan"))
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(plan.indices, id: \.self) { index in
                        let entry = plan[index]
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: iconName(for: entry.status))
                                .foregroundStyle(iconColor(for: entry.status))
                            Text(entry.content)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            ForEach(activity.items) { item in
                if item.id != activity.items.first?.id || !plan.isEmpty { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    if let status = item.status {
                        Text(verbatim: status)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !item.lines.isEmpty {
                        Text(verbatim: item.lines.joined(separator: "\n"))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.id)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.id)
                .accessibilityValue(item.text)
            }
        }
    }

    private func iconName(for status: AgentHostACPPlanStatus) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func iconColor(for status: AgentHostACPPlanStatus) -> Color {
        switch status {
        case .pending: Color.secondary
        case .inProgress: Color.accentColor
        case .completed: Color.green
        }
    }
}

private struct ContextUsageIndicator: View {
    let usage: AgentHostContextUsage?
    let cost: AgentHostACPSessionCost?
    @State private var isContextUsagePresented = false

    private var presentation: ContextUsagePresentation? {
        usage.map(ContextUsagePresentation.init)
    }

    var body: some View {
        Button {
            isContextUsagePresented.toggle()
        } label: {
            Group {
                if let presentation {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 3)

                        Circle()
                            .trim(from: 0, to: presentation.progress)
                            .stroke(
                                Color.primary.opacity(0.58),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 17, height: 17)
                } else {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .frame(width: 28, height: 32)
        }
        .buttonStyle(
            RoundedInteractionButtonStyle(
                cornerRadius: 9,
                isSelected: isContextUsagePresented
            )
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("context-usage-indicator")
        .onHover { isContextUsagePresented = $0 }
        .popover(isPresented: $isContextUsagePresented, arrowEdge: .top) {
            VStack(spacing: 9) {
                if let presentation {
                    Text(L10n.string("chat.context_window"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.48))

                    Text(presentation.percentText)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.68))

                    Text(presentation.detailText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.88))
                }

                if presentation != nil, cost != nil {
                    Divider()
                }

                if let costText {
                    Text(L10n.string("chat.session_cost"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.48))
                    Text(costText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.88))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minWidth: 220)
        }
    }

    private var accessibilityLabel: String {
        [
            presentation?.accessibilityLabel,
            costText.map { "\(L10n.string("chat.session_cost")): \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private var costText: String? {
        guard let cost else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = L10n.currentLanguage.locale
        formatter.currencyCode = cost.currency.uppercased()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: cost.amount))
            ?? "\(cost.amount) \(cost.currency.uppercased())"
    }
}

private struct ComposerImagePreview: View {
    @Environment(\.dismiss) private var dismiss

    let data: Data

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            Group {
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(L10n.string("chat.image.preview"))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(L10n.string("common.done"))
            .accessibilityLabel(L10n.string("common.done"))
            .padding(16)
        }
        .frame(
            minWidth: 560,
            idealWidth: 800,
            maxWidth: 1_000,
            minHeight: 420,
            idealHeight: 600,
            maxHeight: 800
        )
        .accessibilityIdentifier("image-attachment-preview")
    }
}

private struct FastModeCapsuleSwitch: View {
    let isOn: Bool
    let isAvailable: Bool

    private var trackOpacity: Double {
        guard isAvailable else { return 0.07 }
        return isOn ? 0.72 : 0.16
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.primary.opacity(trackOpacity))

            Circle()
                .fill(AppPalette.raisedSurface)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(isAvailable ? 0.10 : 0.05), lineWidth: 0.5)
                )
                .shadow(color: AppPalette.subtleShadow, radius: 1.5, y: 0.5)
                .frame(width: 14, height: 14)
                .offset(x: isOn ? 7 : -7)
        }
        .frame(width: 32, height: 18)
        .opacity(isAvailable ? 1 : 0.55)
        .animation(.easeOut(duration: 0.16), value: isOn)
    }
}

private struct ModelProviderIcon: View {
    let model: PiModelOption

    var body: some View {
        Image(model.providerIconAssetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.primary)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

private struct ComposerSurfaceMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> ComposerSurfaceView {
        ComposerSurfaceView()
    }

    func updateNSView(_ nsView: ComposerSurfaceView, context: Context) {}
}

private struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let leadingExclusionWidth: CGFloat
    let focusRequest: Int
    let onEditorCommand: (SessionComposerEditorCommand) -> Bool
    let onPasteboard: (NSPasteboard) -> Bool
    let onCompositionChange: (Bool) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = ComposerTextView(frame: NSRect(
            x: 0,
            y: 0,
            width: 1,
            height: SessionComposerState.minimumEditorHeight
        ))
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: SessionComposerState.minimumEditorHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let coordinator = context.coordinator
        textView.onPasteboard = { [weak coordinator] pasteboard in
            coordinator?.parent.onPasteboard(pasteboard) == true
        }
        textView.onMarkedTextChange = { [weak coordinator] isComposing in
            coordinator?.parent.onCompositionChange(isComposing)
        }

        scrollView.documentView = textView
        context.coordinator.updateExclusionPath(in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }

        context.coordinator.updateExclusionPath(in: textView)

        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        DispatchQueue.main.async {
            context.coordinator.updateLayout(in: scrollView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        var lastFocusRequest = 0

        init(parent: GrowingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard
                let textView = notification.object as? NSTextView,
                let scrollView = textView.enclosingScrollView
            else { return }

            parent.text = textView.string
            parent.onCompositionChange(textView.hasMarkedText())
            updateLayout(in: scrollView)
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onCompositionChange(false)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                guard !textView.hasMarkedText() else { return false }
                if parent.onEditorCommand(.selectPreviousSuggestion) { return true }
                guard SessionComposerState.shouldNavigatePromptHistory(
                    .previous,
                    in: textView.string,
                    selection: textView.selectedRange(),
                    hasMarkedText: textView.hasMarkedText()
                ) else { return false }
                return parent.onEditorCommand(.recallPreviousPrompt)
            case #selector(NSResponder.moveDown(_:)):
                guard !textView.hasMarkedText() else { return false }
                if parent.onEditorCommand(.selectNextSuggestion) { return true }
                guard SessionComposerState.shouldNavigatePromptHistory(
                    .next,
                    in: textView.string,
                    selection: textView.selectedRange(),
                    hasMarkedText: textView.hasMarkedText()
                ) else { return false }
                return parent.onEditorCommand(.recallNextPrompt)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEditorCommand(.dismissSuggestions)
            case #selector(NSResponder.deleteBackward(_:)):
                let selection = textView.selectedRange()
                guard selection.location == 0, selection.length == 0 else { return false }
                return parent.onEditorCommand(.deleteSelectedCommand)
            case #selector(NSResponder.insertNewline(_:)):
                break
            default:
                return false
            }

            let action = SessionComposerState.returnKeyAction(
                isShiftPressed: NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
                hasMarkedText: textView.hasMarkedText()
            )

            switch action {
            case .submit:
                if parent.onEditorCommand(.confirmSuggestion) { return true }
                parent.onSubmit()
                return true
            case .insertNewline:
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case .deferToInputMethod:
                return false
            }
        }

        func updateExclusionPath(in textView: NSTextView) {
            guard
                let textContainer = textView.textContainer,
                let layoutManager = textView.layoutManager,
                let font = textView.font
            else { return }

            let rect = SessionComposerState.slashTokenExclusionRect(
                tokenWidth: parent.leadingExclusionWidth,
                lineHeight: layoutManager.defaultLineHeight(for: font)
            )
            let currentRect = textContainer.exclusionPaths.first?.bounds ?? .zero
            guard currentRect != rect else { return }
            textContainer.exclusionPaths = rect.isEmpty ? [] : [NSBezierPath(rect: rect)]
        }

        func updateLayout(in scrollView: NSScrollView) {
            guard
                let textView = scrollView.documentView as? NSTextView,
                let textContainer = textView.textContainer,
                let layoutManager = textView.layoutManager
            else { return }

            let availableWidth = max(scrollView.contentSize.width, 1)
            textContainer.containerSize = NSSize(
                width: availableWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.setFrameSize(NSSize(width: availableWidth, height: max(parent.height, 1)))
            layoutManager.ensureLayout(for: textContainer)

            let contentHeight = ceil(
                layoutManager.usedRect(for: textContainer).height
                    + textView.textContainerInset.height * 2
            )
            let targetHeight = SessionComposerState.editorHeight(for: contentHeight)
            let documentHeight = max(targetHeight, contentHeight)

            textView.setFrameSize(NSSize(width: availableWidth, height: documentHeight))
            scrollView.hasVerticalScroller = SessionComposerState.editorShouldScroll(
                contentHeight: contentHeight
            )

            if abs(parent.height - targetHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.parent.height = targetHeight
                }
            }
        }
    }
}

private struct SessionSuggestion: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let prompt: String
    let color: Color

    static var defaults: [SessionSuggestion] {
        [
            SessionSuggestion(
                icon: "binoculars",
                title: L10n.string("chat.suggestion.explore.title"),
                prompt: L10n.string("chat.suggestion.explore.prompt"),
                color: .blue
            ),
            SessionSuggestion(
                icon: "hammer",
                title: L10n.string("chat.suggestion.build.title"),
                prompt: L10n.string("chat.suggestion.build.prompt"),
                color: .purple
            ),
            SessionSuggestion(
                icon: "arrow.triangle.2.circlepath",
                title: L10n.string("chat.suggestion.review.title"),
                prompt: L10n.string("chat.suggestion.review.prompt"),
                color: .green
            ),
            SessionSuggestion(
                icon: "ladybug",
                title: L10n.string("chat.suggestion.fix.title"),
                prompt: L10n.string("chat.suggestion.fix.prompt"),
                color: .orange
            )
        ]
    }
}

private struct SessionSuggestionCard: View {
    let suggestion: SessionSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(suggestion.color)

            Spacer(minLength: 0)

            Text(suggestion.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.88))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
        }
        .padding(16)
        .frame(height: 104)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.translucentSurface)
        .adaptiveCornerRadius(20)
        .overlay(
            adaptiveRoundedShape(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.11), lineWidth: 0.5)
        )
        .contentShape(adaptiveRoundedShape(cornerRadius: 20))
    }
}

private struct GitBranchIcon: View {
    var body: some View {
        GitBranchIconShape()
            .stroke(
                Color.primary,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

private struct GitBranchIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 16
        let scaleY = rect.height / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * scaleX, y: y * scaleY)
        }

        var path = Path()
        path.addEllipse(
            in: CGRect(x: 2.5 * scaleX, y: scaleY, width: 3 * scaleX, height: 3 * scaleY)
        )
        path.addEllipse(
            in: CGRect(
                x: 10.5 * scaleX,
                y: 3.5 * scaleY,
                width: 3 * scaleX,
                height: 3 * scaleY
            )
        )
        path.addEllipse(
            in: CGRect(x: 2.5 * scaleX, y: 12 * scaleY, width: 3 * scaleX, height: 3 * scaleY)
        )
        path.move(to: point(4, 4))
        path.addLine(to: point(4, 12))
        path.move(to: point(12, 6.5))
        path.addCurve(
            to: point(5.5, 13.5),
            control1: point(12, 10.5),
            control2: point(9.5, 13.5)
        )
        return path
    }
}

private let assistantMarkdownTheme = Theme.gitHub
    .text {
        ForegroundColor(.primary)
        BackgroundColor(nil)
        FontSize(14)
    }
    .code {
        FontFamilyVariant(.monospaced)
        FontSize(.em(0.85))
        BackgroundColor(Color.primary.opacity(0.07))
    }
    .table { configuration in
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .markdownTableBorderStyle(
                .init(color: Color.primary.opacity(0.10))
            )
            .markdownTableBackgroundStyle(
                .alternatingRows(
                    Color.primary.opacity(0.055),
                    Color.primary.opacity(0.025),
                    header: Color.primary.opacity(0.075)
                )
            )
            .markdownMargin(top: 0, bottom: 16)
    }
    .thematicBreak {
        Color.primary.opacity(0.12)
            .frame(height: 1)
            .markdownMargin(top: 14, bottom: 14)
    }

/// Parsing Markdown happens in `MarkdownContent.init`, so an uncached
/// `Markdown(text)` re-parses on every body pass — including composer
/// keystrokes and streaming updates, which rebuild the whole transcript.
/// Caching by text keeps repeated renders of unchanged messages cheap.
private enum AssistantMarkdownCache {
    private static let cache: NSCache<NSString, CachedContent> = {
        let cache = NSCache<NSString, CachedContent>()
        cache.countLimit = 400
        return cache
    }()

    private final class CachedContent {
        let content: MarkdownContent

        init(_ content: MarkdownContent) {
            self.content = content
        }
    }

    static func content(for text: String) -> MarkdownContent {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached.content
        }
        let parsed = MarkdownContent(text)
        cache.setObject(CachedContent(parsed), forKey: key)
        return parsed
    }
}

private struct ChatMessageRow: View {
    let message: PiChatMessage
    let loadedToolOutputs: [String: String]
    let loadingToolOutputIDs: Set<String>
    let onLoadToolOutput: (SessionToolRecord) -> Void
    let onResolve: (AgentHostApprovalRequest, AgentHostApprovalDecision) -> Void

    @State private var isMessageCopied = false
    @State private var isAssistantMetadataHovered = false
    @State private var isUserMetadataHovered = false
    @State private var isCopyButtonHovered = false
    @State private var copyFeedbackResetTask: Task<Void, Never>?
    @State private var previewedMessageImage: PiChatImageAttachment?

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 7) {
                    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(message.text)
                                .font(.system(size: 14))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(AppPalette.translucentSurface)
                                .adaptiveCornerRadius(14)
                                .shadow(color: AppPalette.subtleShadow, radius: 4, y: 1)

                            if message.hasCopyableText {
                                userMetadata
                            }
                        }
                        .onHover { hovering in
                            isUserMetadataHovered = hovering
                            if !hovering {
                                isCopyButtonHovered = false
                            }
                        }
                    }

                    if !message.imageAttachments.isEmpty {
                        sentImageAttachments
                    }

                    ForEach(message.usedSkills) { skill in
                        SkillUsageRow(skill: skill)
                    }
                }
            }
            .sheet(item: $previewedMessageImage) { image in
                ComposerImagePreview(data: image.data)
            }
        case .assistant:
            HStack(alignment: .top) {
                assistantTimeline
                Spacer(minLength: 60)
            }
        case .tool:
            VStack(alignment: .leading, spacing: 11) {
                ForEach(assistantBlocks) { block in
                    assistantBlock(block)
                }
            }
        case .system:
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.5))
        }
    }

    private var sentImageAttachments: some View {
        HStack(spacing: 8) {
            ForEach(message.imageAttachments) { image in
                Button {
                    previewedMessageImage = image
                } label: {
                    Group {
                        if let preview = NSImage(data: image.data) {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .frame(
                        width: sentImageThumbnailSize.width,
                        height: sentImageThumbnailSize.height
                    )
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help(L10n.string("chat.image.preview"))
                .accessibilityLabel(L10n.string("chat.image.preview"))
                .accessibilityIdentifier("message-image-\(image.id)")
            }
        }
        .frame(maxWidth: 360, alignment: .trailing)
    }

    private var sentImageThumbnailSize: CGSize {
        message.imageAttachments.count == 1
            ? CGSize(width: 180, height: 112)
            : CGSize(width: 64, height: 64)
    }

    private var assistantTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(assistantBlocks) { block in
                    assistantBlock(block)
                }
                if assistantBlocks.isEmpty, message.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .onDisappear {
            copyFeedbackResetTask?.cancel()
        }
    }

    private var assistantBlocks: [AssistantTranscriptBlock] {
        AssistantTranscriptPresentation.blocks(from: message.parts)
    }

    private var assistantMetadataAnchorID: String? {
        guard message.hasCopyableText else { return nil }
        return AssistantTranscriptPresentation.metadataAnchorID(in: assistantBlocks)
    }

    private var assistantMetadata: some View {
        HStack(spacing: 8) {
            Button(action: copyMessage) {
                Image(systemName: MessageCopyFeedback.iconName(isCopied: isMessageCopied))
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 22)
                    .background(
                        adaptiveRoundedShape(cornerRadius: 7)
                            .fill(Color.primary.opacity(isCopyButtonHovered ? 0.08 : 0))
                    )
                    .shadow(
                        color: isCopyButtonHovered ? AppPalette.subtleShadow : Color.clear,
                        radius: 4,
                        y: 1
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
            .help(copyMessageLabel)
            .accessibilityLabel(copyMessageLabel)
            .onHover { isCopyButtonHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isCopyButtonHovered)

            if let timestamp = message.timestamp {
                Text(timestamp, style: .time)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)
        }
        .opacity(isAssistantMetadataHovered ? 1 : 0)
        .allowsHitTesting(isAssistantMetadataHovered)
        .accessibilityHidden(!isAssistantMetadataHovered)
    }

    private var userMetadata: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)

            Button(action: copyMessage) {
                Image(systemName: MessageCopyFeedback.iconName(isCopied: isMessageCopied))
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 22)
                    .background(
                        adaptiveRoundedShape(cornerRadius: 7)
                            .fill(Color.primary.opacity(isCopyButtonHovered ? 0.08 : 0))
                    )
                    .shadow(
                        color: isCopyButtonHovered ? AppPalette.subtleShadow : Color.clear,
                        radius: 4,
                        y: 1
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
            .help(copyMessageLabel)
            .accessibilityLabel(copyMessageLabel)
            .onHover { isCopyButtonHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isCopyButtonHovered)

            if let timestamp = message.timestamp {
                Text(timestamp, style: .time)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }
        }
        .opacity(isUserMetadataHovered ? 1 : 0)
        .allowsHitTesting(isUserMetadataHovered)
        .accessibilityHidden(!isUserMetadataHovered)
    }

    private var copyMessageLabel: String {
        if isMessageCopied {
            return L10n.string("chat.message.copied")
        }
        return L10n.string("chat.message.copy")
    }

    private func copyMessage() {
        guard MessageClipboard.copy(message.copyableText) else { return }
        copyFeedbackResetTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            isMessageCopied = true
        }
        copyFeedbackResetTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    nanoseconds: MessageCopyFeedback.resetDelayNanoseconds
                )
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.12)) {
                isMessageCopied = false
            }
        }
    }

    @ViewBuilder
    private func assistantBlock(_ block: AssistantTranscriptBlock) -> some View {
        switch block {
        case .text(let id, let text):
            VStack(alignment: .leading, spacing: 4) {
                Markdown(AssistantMarkdownCache.content(for: text))
                    .markdownTheme(assistantMarkdownTheme)
                    .textSelection(.enabled)
                if id == assistantMetadataAnchorID {
                    assistantMetadata
                }
            }
            .padding(.leading, 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard id == assistantMetadataAnchorID else { return }
                isAssistantMetadataHovered = hovering
                if !hovering {
                    isCopyButtonHovered = false
                }
            }
        case .thinking(let thinking):
            AssistantThinkingView(thinking: thinking)
        case .image(_, let mimeType):
            Label(L10n.format("chat.image_attachment", mimeType), systemImage: "photo")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
        case .tools(let group):
            AssistantToolGroupView(
                group: group,
                loadedToolOutputs: loadedToolOutputs,
                loadingToolOutputIDs: loadingToolOutputIDs,
                onLoadToolOutput: onLoadToolOutput,
                onResolve: onResolve
            )
        }
    }
}

private struct SkillUsageRow: View {
    let skill: SessionSkillRecord

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11.5, weight: .medium))

            Text(L10n.format("chat.skill.used", skill.name))
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.primary.opacity(0.5))
        .accessibilityElement(children: .combine)
    }
}

private struct AssistantThinkingView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let thinking: SessionThinkingRecord

    @State private var isExpanded: Bool
    @State private var isHeaderHovered = false

    init(thinking: SessionThinkingRecord) {
        self.thinking = thinking
        _isExpanded = State(initialValue: thinking.state == .running)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpansion) {
                HStack(spacing: 8) {
                    statusIcon

                    Text(L10n.string("chat.thinking.title"))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.62))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.36))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(
                            accessibilityReduceMotion ? nil : .easeOut(duration: 0.16),
                            value: isExpanded
                        )
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(isHeaderHovered ? 0.045 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHeaderHovered = $0 }
            .accessibilityLabel(L10n.string("chat.thinking.title"))
            .accessibilityValue(
                thinking.state == .running
                    ? L10n.string("chat.thinking.running")
                    : ""
            )
            .accessibilityHint(
                L10n.string(
                    isExpanded
                        ? "chat.thinking.collapse"
                        : "chat.thinking.expand"
                )
            )

            if isExpanded,
               !thinking.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: thinking.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                    .padding(.top, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if thinking.state == .running {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.32))
                .frame(width: 16, height: 16)
        }
    }

    private func toggleExpansion() {
        isExpanded.toggle()
    }
}

private struct AssistantToolGroupView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let group: AssistantToolGroup
    let loadedToolOutputs: [String: String]
    let loadingToolOutputIDs: Set<String>
    let onLoadToolOutput: (SessionToolRecord) -> Void
    let onResolve: (AgentHostApprovalRequest, AgentHostApprovalDecision) -> Void

    @State private var manualExpansion: Bool?
    @State private var isHeaderHovered = false
    @FocusState private var isHeaderFocused: Bool

    init(
        group: AssistantToolGroup,
        loadedToolOutputs: [String: String],
        loadingToolOutputIDs: Set<String>,
        onLoadToolOutput: @escaping (SessionToolRecord) -> Void,
        onResolve: @escaping (AgentHostApprovalRequest, AgentHostApprovalDecision) -> Void
    ) {
        self.group = group
        self.loadedToolOutputs = loadedToolOutputs
        self.loadingToolOutputIDs = loadingToolOutputIDs
        self.onLoadToolOutput = onLoadToolOutput
        self.onResolve = onResolve
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard canToggleExpansion else { return }
                manualExpansion = !isExpanded
            } label: {
                HStack(spacing: 8) {
                    statusIcon

                    Text(statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.58))

                    if canToggleExpansion {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.36))
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                            .animation(
                                accessibilityReduceMotion ? nil : .easeOut(duration: 0.14),
                                value: isExpanded
                            )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            Color.primary.opacity(
                                isHeaderHovered || isHeaderFocused ? 0.045 : 0
                            )
                        )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isHeaderFocused)
            .onHover { isHeaderHovered = $0 }
            .accessibilityLabel(statusText)
            .accessibilityHint(
                canToggleExpansion
                    ? L10n.string(isExpanded ? "chat.steps.collapse" : "chat.steps.expand")
                    : ""
            )

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.tools) { tool in
                        AssistantToolStepRow(
                            tool: tool,
                            loadedOutput: loadedToolOutputs[tool.id],
                            isLoadingFullOutput: loadingToolOutputIDs.contains(tool.id),
                            onLoadFullOutput: { onLoadToolOutput(tool) },
                            onResolve: onResolve
                        )
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 1)
                }
                .padding(.leading, 13)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isExpanded: Bool {
        group.status.isExpanded(manualSelection: manualExpansion)
    }

    private var canToggleExpansion: Bool {
        group.status != .approvalRequired
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch group.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
        case .approvalRequired:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.orange)
                .frame(width: 16, height: 16)
        case .failed, .completed:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.32))
                .frame(width: 16, height: 16)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.32))
                .frame(width: 16, height: 16)
        }
    }

    private var statusText: String {
        switch group.status {
        case .running(let completed, let total):
            return L10n.format("chat.steps.running", completed, total)
        case .approvalRequired:
            return L10n.string("chat.steps.approval_required")
        case .failed(let total, _):
            return L10n.format("chat.steps.completed", total)
        case .completed(let total):
            return L10n.format("chat.steps.completed", total)
        case .cancelled(let total):
            return L10n.format("chat.steps.cancelled", total)
        }
    }
}

private struct AssistantToolStepRow: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let tool: SessionToolRecord
    let loadedOutput: String?
    let isLoadingFullOutput: Bool
    let onLoadFullOutput: () -> Void
    let onResolve: (AgentHostApprovalRequest, AgentHostApprovalDecision) -> Void

    @State private var isDetailExpanded = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasDetails else { return }
                isDetailExpanded.toggle()
                if isDetailExpanded, tool.outputTruncated, loadedOutput == nil {
                    onLoadFullOutput()
                }
            } label: {
                HStack(spacing: 8) {
                    statusIcon

                    Text(presentation.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.68))

                    if !presentation.summary.isEmpty {
                        Text(presentation.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.38))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    if showsExceptionalStatus {
                        Text(statusText)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(statusColor)
                    }

                    if hasDetails {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.28))
                            .rotationEffect(.degrees(showsDetails ? 90 : 0))
                            .animation(
                                accessibilityReduceMotion ? nil : .easeOut(duration: 0.14),
                                value: showsDetails
                            )
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isHovered || isFocused ? 0.04 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .onHover { isHovered = $0 }
            .accessibilityLabel("\(presentation.title), \(statusText)")
            .accessibilityHint(
                hasDetails
                    ? L10n.string(showsDetails ? "chat.steps.collapse" : "chat.steps.expand")
                    : ""
            )

            if showsDetails {
                VStack(alignment: .leading, spacing: 10) {
                    if tool.rawInput != nil || !tool.summary.isEmpty {
                        ToolDetailBlock(
                            title: L10n.string("chat.tool.input"),
                            text: presentation.formattedInput
                        )
                    }
                    if hasOutputDetails {
                        ToolDetailBlock(
                            title: L10n.string("chat.tool.output"),
                            text: loadedOutput ?? outputForDisplay
                        )
                    }
                    if !tool.content.isEmpty {
                        ToolStructuredContentView(contents: tool.content)
                    }
                    if isLoadingFullOutput {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let approval = tool.approval {
                        InlineApprovalActions(approval: approval) { decision in
                            onResolve(approval, decision)
                        }
                    }
                }
                .padding(.leading, 23)
                .padding(.trailing, 4)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if showsDetails, tool.outputTruncated, loadedOutput == nil {
                onLoadFullOutput()
            }
        }
    }

    private var showsDetails: Bool {
        tool.state == .awaitingApproval
            || isDetailExpanded
    }

    private var hasDetails: Bool {
        !tool.summary.isEmpty || !tool.output.isEmpty || !tool.content.isEmpty
            || tool.rawInput != nil || tool.rawOutput != nil || tool.approval != nil
    }

    private var hasOutputDetails: Bool {
        !outputForDisplay.isEmpty || loadedOutput != nil
    }

    private var outputForDisplay: String {
        toolOutputForDisplay(output: tool.output, rawOutput: tool.rawOutput)
    }

    private var showsExceptionalStatus: Bool {
        tool.state == .awaitingApproval
    }

    private var statusIcon: some View {
        Image(systemName: presentation.iconName)
            .font(.system(size: 12))
            .foregroundStyle(statusColor)
            .frame(width: 14, height: 14)
    }

    private var statusText: String {
        switch tool.state {
        case .running:
            return L10n.string("chat.tool.running")
        case .awaitingApproval:
            return L10n.string("chat.tool.awaiting_approval")
        case .completed:
            return L10n.string(tool.isError == true ? "chat.tool.failed" : "chat.tool.completed")
        case .cancelled:
            return L10n.string("chat.tool.cancelled")
        }
    }

    private var statusColor: Color {
        if tool.state == .awaitingApproval { return .orange }
        if tool.isError == true { return .red }
        return Color.primary.opacity(0.34)
    }

    private var presentation: ToolCallPresentation {
        ToolCallPresentation(tool: tool)
    }
}

private struct ToolDetailBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .textCase(.uppercase)

                Spacer(minLength: 8)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
                .accessibilityLabel(L10n.string("chat.tool.copy"))
            }

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(9)
            }
            .frame(maxHeight: 220)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045))
            .adaptiveCornerRadius(8)
        }
    }
}

private struct ToolStructuredContentView: View {
    let contents: [AgentHostACPToolCallContent]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(contents.indices, id: \.self) { index in
                contentView(contents[index])
            }
        }
    }

    @ViewBuilder
    private func contentView(_ content: AgentHostACPToolCallContent) -> some View {
        switch content {
        case .content(.text):
            EmptyView()
        case .content(.image(let mimeType, let data, let uri)):
            ToolImageBlock(mimeType: mimeType, data: data, uri: uri)
        case .content(.audio(let mimeType, _)):
            Label(
                "\(L10n.string("chat.tool.audio")) · \(mimeType)",
                systemImage: "waveform"
            )
            .font(.system(size: 12))
            .foregroundStyle(Color.secondary)
        case .content(
            .resourceLink(
                let name,
                let uri,
                let title,
                let description,
                let mimeType
            )
        ):
            ToolResourceLinkBlock(
                name: name,
                uri: uri,
                title: title,
                description: description,
                mimeType: mimeType
            )
        case .content(.resource(let uri, let mimeType, let text, let data)):
            if let text {
                ToolDetailBlock(title: uri, text: text)
            } else if let mimeType, mimeType.hasPrefix("image/") {
                ToolImageBlock(mimeType: mimeType, data: data, uri: uri)
            } else {
                Label(uri, systemImage: "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                    .textSelection(.enabled)
            }
        case .content(.unsupported(let type)), .unsupported(let type):
            Label(
                "\(L10n.string("chat.tool.unsupported_content")): \(type)",
                systemImage: "questionmark.square.dashed"
            )
            .font(.system(size: 12))
            .foregroundStyle(Color.secondary)
        case .diff(let path, let oldText, let newText):
            ToolDiffBlock(path: path, oldText: oldText, newText: newText)
        case .terminal(let id):
            Label(
                "\(L10n.string("chat.tool.terminal_reference")): \(id)",
                systemImage: "terminal"
            )
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.secondary)
            .textSelection(.enabled)
        }
    }
}

private struct ToolImageBlock: View {
    let mimeType: String
    let data: Data?
    let uri: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.string("chat.tool.image"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .textCase(.uppercase)

            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 320, alignment: .leading)
                    .adaptiveCornerRadius(8)
                    .accessibilityIdentifier("tool-structured-image")
            } else {
                Label(uri ?? mimeType, systemImage: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}

private struct ToolResourceLinkBlock: View {
    let name: String
    let uri: String
    let title: String?
    let description: String?
    let mimeType: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = URL(string: uri) {
                Link(destination: url) {
                    Label(title ?? name, systemImage: "link")
                }
            } else {
                Label(title ?? name, systemImage: "link")
            }

            if let description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }

            Text([mimeType, uri].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ToolDiffBlock: View {
    let path: String
    let oldText: String?
    let newText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(path, systemImage: "square.and.pencil")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.secondary)
                .textSelection(.enabled)

            HStack(alignment: .top, spacing: 8) {
                if let oldText {
                    diffColumn(
                        title: L10n.string("chat.tool.diff_before"),
                        text: oldText,
                        color: .red
                    )
                }
                diffColumn(
                    title: L10n.string("chat.tool.diff_after"),
                    text: newText,
                    color: .green
                )
            }
        }
    }

    private func diffColumn(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color.opacity(0.8))
                .textCase(.uppercase)
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
            }
            .frame(maxHeight: 240)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.06))
            .adaptiveCornerRadius(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ACPElicitationFormState {
    let request: AgentHostACPElicitationRequest
    var textValues: [String: String] = [:]
    var booleanValues: [String: Bool] = [:]
    var selectionValues: [String: Set<String>] = [:]

    init(request: AgentHostACPElicitationRequest) {
        self.request = request
        for (key, property) in request.schema.properties {
            switch property.type {
            case .string:
                if case .string(let value) = property.defaultValue {
                    textValues[key] = value
                } else {
                    textValues[key] = property.options.first?.value ?? ""
                }
            case .integer:
                if case .integer(let value) = property.defaultValue {
                    textValues[key] = String(value)
                } else {
                    textValues[key] = ""
                }
            case .number:
                if case .number(let value) = property.defaultValue {
                    textValues[key] = String(value)
                } else if case .integer(let value) = property.defaultValue {
                    textValues[key] = String(value)
                } else {
                    textValues[key] = ""
                }
            case .boolean:
                if case .boolean(let value) = property.defaultValue {
                    booleanValues[key] = value
                } else {
                    booleanValues[key] = false
                }
            case .array:
                if case .stringArray(let values) = property.defaultValue {
                    selectionValues[key] = Set(values)
                } else {
                    selectionValues[key] = []
                }
            }
        }
    }

    var content: [String: AgentHostACPElicitationValue]? {
        var result: [String: AgentHostACPElicitationValue] = [:]
        let required = Set(request.schema.required)
        for (key, property) in request.schema.properties {
            switch property.type {
            case .string:
                let value = textValues[key] ?? ""
                if required.contains(key) || !value.isEmpty {
                    guard isValidString(value, property: property) else { return nil }
                    result[key] = .string(value)
                }
            case .integer:
                let rawValue = textValues[key] ?? ""
                guard !rawValue.isEmpty || !required.contains(key) else { return nil }
                guard !rawValue.isEmpty else { continue }
                guard let value = Int(rawValue), isWithinBounds(Double(value), property: property) else {
                    return nil
                }
                result[key] = .integer(value)
            case .number:
                let rawValue = textValues[key] ?? ""
                guard !rawValue.isEmpty || !required.contains(key) else { return nil }
                guard !rawValue.isEmpty else { continue }
                guard let value = Double(rawValue), value.isFinite,
                      isWithinBounds(value, property: property) else {
                    return nil
                }
                result[key] = .number(value)
            case .boolean:
                result[key] = .boolean(booleanValues[key] ?? false)
            case .array:
                let values = selectionValues[key, default: []].sorted()
                if let minimum = property.minItems, values.count < minimum { return nil }
                if let maximum = property.maxItems, values.count > maximum { return nil }
                if required.contains(key) || !values.isEmpty {
                    result[key] = .stringArray(values)
                }
            }
        }
        return result
    }

    private func isWithinBounds(
        _ value: Double,
        property: AgentHostACPElicitationProperty
    ) -> Bool {
        if let minimum = property.minimum, value < minimum { return false }
        if let maximum = property.maximum, value > maximum { return false }
        return true
    }

    private func isValidString(
        _ value: String,
        property: AgentHostACPElicitationProperty
    ) -> Bool {
        if let minimum = property.minLength, value.count < minimum { return false }
        if let maximum = property.maxLength, value.count > maximum { return false }
        if let pattern = property.pattern,
           value.range(of: pattern, options: .regularExpression) == nil {
            return false
        }
        switch property.format {
        case .email:
            return value.range(
                of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#,
                options: .regularExpression
            ) != nil
        case .uri:
            return URLComponents(string: value)?.scheme?.isEmpty == false
        case .date:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: value) else { return false }
            return formatter.string(from: date) == value
        case .dateTime:
            return ISO8601DateFormatter().date(from: value) != nil
        case nil:
            return true
        }
    }
}

private struct ACPElicitationFormView: View {
    let request: AgentHostACPElicitationRequest
    let onRespond: (AgentHostACPElicitationResponse) -> Void

    @State private var state: ACPElicitationFormState

    init(
        request: AgentHostACPElicitationRequest,
        onRespond: @escaping (AgentHostACPElicitationResponse) -> Void
    ) {
        self.request = request
        self.onRespond = onRespond
        _state = State(initialValue: ACPElicitationFormState(request: request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.schema.title ?? request.message)
                    .font(.system(size: 18, weight: .semibold))
                if request.schema.title != nil {
                    Text(request.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if let description = request.schema.description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(request.schema.properties.keys.sorted(), id: \.self) { key in
                        if let property = request.schema.properties[key] {
                            field(key: key, property: property)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if state.content == nil {
                Text(L10n.string("chat.elicitation.invalid"))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Button(L10n.string("common.cancel")) {
                    onRespond(.cancel)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.string("chat.elicitation.decline")) {
                    onRespond(.decline)
                }

                Button(L10n.string("chat.elicitation.submit")) {
                    if let content = state.content {
                        onRespond(.accept(content))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.content == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 260, maxHeight: 640)
        .accessibilityIdentifier("acp-elicitation-form")
    }

    @ViewBuilder
    private func field(
        key: String,
        property: AgentHostACPElicitationProperty
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fieldTitle(key: key, property: property))
                .font(.system(size: 12, weight: .semibold))
            if let description = property.description {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            switch property.type {
            case .string where !property.options.isEmpty:
                Picker("", selection: textBinding(for: key)) {
                    ForEach(property.options) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            case .string, .integer, .number:
                TextField("", text: textBinding(for: key), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
            case .boolean:
                Toggle(isOn: booleanBinding(for: key)) {
                    Text(L10n.string("chat.enabled"))
                }
            case .array:
                ForEach(property.options) { option in
                    Toggle(isOn: selectionBinding(for: key, value: option.value)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            if let description = option.description {
                                Text(description)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func fieldTitle(
        key: String,
        property: AgentHostACPElicitationProperty
    ) -> String {
        let title = property.title ?? key
        return request.schema.required.contains(key) ? "\(title) *" : title
    }

    private func textBinding(for key: String) -> Binding<String> {
        Binding(
            get: { state.textValues[key] ?? "" },
            set: { state.textValues[key] = $0 }
        )
    }

    private func booleanBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { state.booleanValues[key] ?? false },
            set: { state.booleanValues[key] = $0 }
        )
    }

    private func selectionBinding(for key: String, value: String) -> Binding<Bool> {
        Binding(
            get: { state.selectionValues[key, default: []].contains(value) },
            set: { isSelected in
                if isSelected {
                    state.selectionValues[key, default: []].insert(value)
                } else {
                    state.selectionValues[key, default: []].remove(value)
                }
            }
        )
    }
}

private struct InlineApprovalActions: View {
    let approval: AgentHostApprovalRequest
    let onResolve: (AgentHostApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.string("chat.approval.title"), systemImage: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)

            HStack {
                Spacer(minLength: 0)

                ForEach(options) { option in
                    Button(option.name) {
                        onResolve(option.kind.decision)
                    }
                    .buttonStyle(.bordered)
                    .tint(option.kind.isAllow ? Color.accentColor : Color.red)
                    .accessibilityIdentifier("approval-\(option.kind.rawValue)")
                }
            }
        }
    }

    private var options: [AgentHostApprovalOption] {
        if !approval.options.isEmpty { return approval.options }
        return [
            AgentHostApprovalOption(
                optionId: "reject-once",
                name: L10n.string("chat.approval.deny"),
                kind: .rejectOnce
            ),
            AgentHostApprovalOption(
                optionId: "allow-once",
                name: L10n.string("chat.approval.allow_once"),
                kind: .allowOnce
            )
        ]
    }
}

private struct ToolCallPresentation {
    let tool: SessionToolRecord

    var title: String {
        tool.name.replacingOccurrences(of: "_", with: " ")
    }

    var iconName: String {
        switch tool.name {
        case "read": return "book"
        case "bash": return "terminal"
        case "write", "edit": return "square.and.pencil"
        case "grep", "find": return "magnifyingglass"
        case "ls": return "folder"
        case "web_search": return "magnifyingglass"
        case "web_fetch", "fetch_content": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    var summary: String {
        guard let data = tool.summary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return tool.summary
        }
        for key in ["path", "command", "query", "url", "pattern"] {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return tool.summary
    }

    var formattedInput: String {
        if let rawInput = tool.rawInput?.prettyPrinted {
            return rawInput
        }
        guard let data = tool.summary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let string = String(data: formatted, encoding: .utf8) else {
            return tool.summary
        }
        return string
    }

}
