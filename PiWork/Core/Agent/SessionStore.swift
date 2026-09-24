import Foundation
import Combine

enum SessionRecordRunState: Equatable {
    case opening
    case idle
    case submitting
    case running
    case stopping
    case failed

    var showsSidebarActivity: Bool {
        switch self {
        case .submitting, .running, .stopping:
            return true
        case .opening, .idle, .failed:
            return false
        }
    }
}

enum SessionToolRunState: Equatable {
    case running
    case awaitingApproval
    case completed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .cancelled
    }
}

struct SessionToolRecord: Equatable, Identifiable {
    let id: String
    let name: String
    let summary: String
    let output: String
    let content: [AgentHostACPToolCallContent]
    let rawInput: AgentHostJSONValue?
    let rawOutput: AgentHostJSONValue?
    let outputTruncated: Bool
    let outputByteCount: Int?
    let state: SessionToolRunState
    let isError: Bool?
    let approval: AgentHostApprovalRequest?

    init(
        id: String,
        name: String,
        summary: String,
        output: String = "",
        content: [AgentHostACPToolCallContent] = [],
        rawInput: AgentHostJSONValue? = nil,
        rawOutput: AgentHostJSONValue? = nil,
        outputTruncated: Bool = false,
        outputByteCount: Int? = nil,
        state: SessionToolRunState,
        isError: Bool?,
        approval: AgentHostApprovalRequest? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.output = output
        self.content = content
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.outputTruncated = outputTruncated
        self.outputByteCount = outputByteCount
        self.state = state
        self.isError = isError
        self.approval = approval
    }
}

enum SessionThinkingRunState: Equatable {
    case running
    case completed
}

struct SessionThinkingRecord: Equatable, Identifiable {
    let id: String
    let text: String
    let state: SessionThinkingRunState
    let redacted: Bool
}

struct SessionSkillRecord: Equatable, Identifiable {
    let id: String
    let name: String
}

enum SessionTranscriptPart: Equatable, Identifiable {
    case text(id: String, text: String)
    case skill(SessionSkillRecord)
    case thinking(SessionThinkingRecord)
    case image(id: String, mimeType: String, data: Data?)
    case tool(SessionToolRecord)

    var id: String {
        switch self {
        case .text(let id, _), .image(let id, _, _):
            return id
        case .skill(let skill):
            return skill.id
        case .thinking(let thinking):
            return thinking.id
        case .tool(let tool):
            return "tool:\(tool.id)"
        }
    }
}

struct SessionTranscriptMessage: Equatable, Identifiable {
    let id: String
    let role: AgentHostSessionMessageRole
    var parts: [SessionTranscriptPart]
    let timestamp: String
}

struct SessionRecord: Equatable, Identifiable {
    var id: String { descriptor.id }

    var descriptor: AgentHostSessionDescriptor
    let profile: AgentHostSessionProfile
    let sessionDirectory: String?
    var messages: [AgentHostSessionMessage]
    var tools: [SessionToolRecord]
    var transcript: [SessionTranscriptMessage]
    var historyCursor: String?
    var historyRevision: String?
    var hasEarlierMessages: Bool
    var runState: SessionRecordRunState
    var lastSequence: Int
    var activeTurnId: String?
    var gitBranch: String?
    var model: AgentHostModel?
    var contextUsage: AgentHostContextUsage?
    var thinkingLevel: AgentHostThinkingLevel
    var availableThinkingLevels: [AgentHostThinkingLevel]
    var modelOptions: AgentHostModelOptions
    var accessMode: AgentHostAccessMode
    var pendingApprovals: [AgentHostApprovalRequest]
    var pendingElicitations: [AgentHostACPElicitationRequest] = []
    var errorMessage: String?
    var acpState: AgentHostACPSessionState
}

enum SessionStoreEffect: Equatable {
    case requestSnapshot(sessionId: String)
    case renameSession(sessionId: String, title: String)
}

struct SessionStoreReducer {
    private(set) var records: [String: SessionRecord] = [:]

    mutating func apply(
        snapshot: AgentHostSessionSnapshotResult,
        profile: AgentHostSessionProfile,
        sessionDirectory: String?
    ) {
        apply(Self.project(
            snapshot: snapshot,
            profile: profile,
            sessionDirectory: sessionDirectory
        ))
    }

    mutating func apply(_ record: SessionRecord) {
        records[record.id] = record
    }

    mutating func applyACPState(
        _ state: AgentHostACPSessionState,
        sessionId: String
    ) {
        guard var record = records[sessionId] else { return }
        if let modes = state.modes {
            record.acpState.modes = modes
        }
        record.acpState.configOptions = state.configOptions
        if let cost = state.cost {
            record.acpState.cost = cost
        }
        if let availableCommands = state.availableCommands {
            record.acpState.availableCommands = availableCommands
        }
        if let plan = state.plan {
            record.acpState.plan = plan
        }
        if !state.extensionStatuses.isEmpty {
            record.acpState.extensionStatuses.merge(state.extensionStatuses) { _, latest in latest }
        }
        if !state.extensionWidgets.isEmpty {
            record.acpState.extensionWidgets.merge(state.extensionWidgets) { _, latest in latest }
        }
        if let updatedAt = state.updatedAt {
            record.acpState.updatedAt = updatedAt
        }
        record.acpState.supportsImages = state.supportsImages
        if let model = record.acpState.model, record.model != model {
            record.model = model
        }
        record.thinkingLevel = record.acpState.thinkingLevel ?? record.thinkingLevel
        record.availableThinkingLevels = record.acpState.availableThinkingLevels
        record.modelOptions = record.acpState.modelOptions
        record.accessMode = record.acpState.accessMode ?? record.accessMode
        records[sessionId] = record
    }

    static func project(
        snapshot: AgentHostSessionSnapshotResult,
        profile: AgentHostSessionProfile,
        sessionDirectory: String?
    ) -> SessionRecord {
        let transcript = makeTranscript(
            from: snapshot.messages,
            pendingApprovals: snapshot.pendingApprovals,
            sessionState: snapshot.state
        )
        let tools: [SessionToolRecord] = transcript.flatMap(\.parts).compactMap { part -> SessionToolRecord? in
            guard case .tool(let tool) = part else { return nil }
            return tool
        }
        return SessionRecord(
            descriptor: snapshot.session,
            profile: profile,
            sessionDirectory: sessionDirectory,
            messages: snapshot.messages,
            tools: tools,
            transcript: transcript,
            historyCursor: snapshot.history?.nextCursor,
            historyRevision: snapshot.history?.revision,
            hasEarlierMessages: snapshot.history?.hasMore == true,
            runState: snapshot.state == .running ? .running : .idle,
            lastSequence: snapshot.sequence,
            activeTurnId: snapshot.turnId,
            gitBranch: snapshot.gitBranch,
            model: snapshot.model,
            contextUsage: snapshot.contextUsage,
            thinkingLevel: snapshot.thinkingLevel,
            availableThinkingLevels: snapshot.availableThinkingLevels,
            modelOptions: snapshot.modelOptions,
            accessMode: snapshot.accessMode,
            pendingApprovals: snapshot.pendingApprovals,
            errorMessage: nil,
            acpState: AgentHostACPSessionState(
                plan: snapshot.plan,
                extensionStatuses: snapshot.extensionStatuses ?? [:],
                extensionWidgets: snapshot.extensionWidgets ?? [:]
            )
        )
    }

    static func project(
        summary: AgentHostSessionSummary,
        profile: AgentHostSessionProfile,
        sessionDirectory: String?,
        acpState: AgentHostACPSessionState = .empty
    ) -> SessionRecord {
        SessionRecord(
            descriptor: AgentHostSessionDescriptor(
                id: summary.id,
                path: summary.path,
                cwd: summary.cwd,
                title: summary.title
            ),
            profile: profile,
            sessionDirectory: sessionDirectory,
            messages: [],
            tools: [],
            transcript: [],
            historyCursor: nil,
            historyRevision: nil,
            hasEarlierMessages: false,
            runState: .idle,
            lastSequence: 0,
            activeTurnId: nil,
            gitBranch: nil,
            model: acpState.model,
            contextUsage: nil,
            thinkingLevel: acpState.thinkingLevel ?? .off,
            availableThinkingLevels: acpState.availableThinkingLevels,
            modelOptions: acpState.modelOptions,
            accessMode: acpState.accessMode ?? (profile == .chat ? .none : .ask),
            pendingApprovals: [],
            errorMessage: nil,
            acpState: acpState
        )
    }

    mutating func prependTranscriptPage(_ page: AgentHostSessionTranscriptPageResult) -> Int {
        guard var record = records[page.sessionId] else { return 0 }
        let existingIDs = Set(record.messages.map(\.id))
        let earlierMessages = page.messages.filter { !existingIDs.contains($0.id) }
        record.messages = earlierMessages + record.messages
        record.transcript = Self.makeTranscript(
            from: record.messages,
            pendingApprovals: record.pendingApprovals,
            sessionState: record.runState == .running ? .running : .idle
        )
        record.tools = record.transcript.flatMap(\.parts).compactMap { part in
            guard case .tool(let tool) = part else { return nil }
            return tool
        }
        record.historyCursor = page.nextCursor
        record.historyRevision = page.revision
        record.hasEarlierMessages = page.hasMore
        records[page.sessionId] = record
        return earlierMessages.count
    }

    mutating func submitPrompt(
        sessionId: String,
        turnId: String,
        text: String,
        images: [AgentHostPromptImage] = [],
        timestamp: String
    ) -> [SessionStoreEffect] {
        guard var record = records[sessionId],
              record.runState == .idle || record.runState == .failed else {
            return []
        }

        let messageID = "turn:\(turnId):user"
        let invocation = skillInvocation(in: text)
        let visibleText = invocation?.userText ?? text
        let textContent: [AgentHostSessionMessageContent] = if let invocation {
            [.skill(name: invocation.name)]
                + (visibleText.isEmpty ? [] : [.text(visibleText)])
        } else {
            text.isEmpty ? [] : [.text(text)]
        }
        let textParts: [SessionTranscriptPart] = if let invocation {
            [
                .skill(
                    SessionSkillRecord(
                        id: "\(messageID):skill:0",
                        name: invocation.name
                    )
                )
            ] + (visibleText.isEmpty
                ? []
                : [.text(id: "\(messageID):text:0", text: visibleText)])
        } else {
            text.isEmpty ? [] : [.text(id: "\(messageID):text:0", text: text)]
        }
        let messageContent = textContent + images.map {
            AgentHostSessionMessageContent.image(mimeType: $0.mimeType, data: $0.data)
        }
        let transcriptParts = textParts + images.enumerated().map { index, image in
            SessionTranscriptPart.image(
                id: "\(messageID):image:\(index)",
                mimeType: image.mimeType,
                data: image.data
            )
        }

        record.messages.append(
            AgentHostSessionMessage(
                id: messageID,
                role: .user,
                content: messageContent,
                timestamp: timestamp,
                provider: nil,
                model: nil,
                stopReason: nil,
                errorMessage: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil
            )
        )
        record.transcript.append(
            SessionTranscriptMessage(
                id: messageID,
                role: .user,
                parts: transcriptParts,
                timestamp: timestamp
            )
        )
        record.runState = .submitting
        record.activeTurnId = turnId
        record.errorMessage = nil

        var effects: [SessionStoreEffect] = []
        if record.descriptor.title == "New Session",
           let title = makeSessionTitle(from: text) {
            record.descriptor = AgentHostSessionDescriptor(
                id: record.descriptor.id,
                path: record.descriptor.path,
                cwd: record.descriptor.cwd,
                title: title
            )
            effects.append(.renameSession(sessionId: sessionId, title: title))
        }
        records[sessionId] = record
        return effects
    }

    mutating func promptAccepted(sessionId: String, turnId: String) {
        guard var record = records[sessionId], record.activeTurnId == turnId else { return }
        if record.runState == .submitting {
            record.runState = .running
        }
        records[sessionId] = record
    }

    mutating func promptCompleted(sessionId: String, turnId: String) {
        guard var record = records[sessionId], record.activeTurnId == turnId else { return }
        finishUnfinishedTools(in: &record, state: .cancelled)
        finishUnfinishedThinking(in: &record)
        record.runState = .idle
        record.activeTurnId = nil
        record.pendingApprovals = []
        records[sessionId] = record
    }

    mutating func promptFailed(sessionId: String, turnId: String, message: String) {
        guard var record = records[sessionId], record.activeTurnId == turnId else { return }
        record.runState = .failed
        record.activeTurnId = nil
        record.errorMessage = message
        records[sessionId] = record
    }

    mutating func revertGeneratedTitle(sessionId: String, title: String) {
        guard var record = records[sessionId], record.descriptor.title == title else { return }
        record.descriptor = AgentHostSessionDescriptor(
            id: record.descriptor.id,
            path: record.descriptor.path,
            cwd: record.descriptor.cwd,
            title: "New Session"
        )
        records[sessionId] = record
    }

    mutating func requestAbort(sessionId: String) {
        guard var record = records[sessionId],
              record.runState == .running || record.runState == .submitting else {
            return
        }
        record.runState = .stopping
        records[sessionId] = record
    }

    mutating func selectModel(
        sessionId: String,
        model: AgentHostModel,
        contextUsage: AgentHostContextUsage?,
        thinkingLevel: AgentHostThinkingLevel,
        availableThinkingLevels: [AgentHostThinkingLevel],
        modelOptions: AgentHostModelOptions
    ) {
        guard var record = records[sessionId] else { return }
        record.model = model
        record.contextUsage = contextUsage
        record.thinkingLevel = thinkingLevel
        record.availableThinkingLevels = availableThinkingLevels
        record.modelOptions = modelOptions
        records[sessionId] = record
    }

    mutating func setGitBranch(sessionId: String, branch: String) {
        guard var record = records[sessionId] else { return }
        record.gitBranch = branch
        records[sessionId] = record
    }

    mutating func selectModelOption(
        sessionId: String,
        model: AgentHostModel,
        contextUsage: AgentHostContextUsage?,
        modelOptions: AgentHostModelOptions
    ) {
        guard var record = records[sessionId] else { return }
        record.model = model
        record.contextUsage = contextUsage
        record.modelOptions = modelOptions
        records[sessionId] = record
    }

    mutating func selectThinkingLevel(
        sessionId: String,
        thinkingLevel: AgentHostThinkingLevel,
        availableThinkingLevels: [AgentHostThinkingLevel]
    ) {
        guard var record = records[sessionId] else { return }
        record.thinkingLevel = thinkingLevel
        record.availableThinkingLevels = availableThinkingLevels
        records[sessionId] = record
    }

    mutating func selectAccessMode(
        sessionId: String,
        accessMode: AgentHostAccessMode
    ) {
        guard var record = records[sessionId] else { return }
        record.accessMode = accessMode
        if accessMode != .ask {
            let toolCallIds = Set(record.pendingApprovals.map(\.toolCallId))
            for toolCallId in toolCallIds {
                updateTool(toolCallId: toolCallId, in: &record) { tool in
                    SessionToolRecord(
                        id: tool.id,
                        name: tool.name,
                        summary: tool.summary,
                        output: tool.output,
                        content: tool.content,
                        rawInput: tool.rawInput,
                        rawOutput: tool.rawOutput,
                        state: .running,
                        isError: nil
                    )
                }
            }
            record.pendingApprovals = []
        }
        records[sessionId] = record
    }

    mutating func selectSessionMode(sessionId: String, modeId: String) {
        guard var record = records[sessionId], var modes = record.acpState.modes else { return }
        modes.currentModeId = modeId
        record.acpState.modes = modes
        if let accessMode = AgentHostAccessMode(rawValue: modeId) {
            record.accessMode = accessMode
        }
        records[sessionId] = record
    }

    mutating func resolveApproval(sessionId: String, requestId: String) {
        guard var record = records[sessionId] else { return }
        let request = record.pendingApprovals.first { $0.id == requestId }
        record.pendingApprovals.removeAll { $0.id == requestId }
        if let toolCallId = request?.toolCallId {
            updateTool(toolCallId: toolCallId, in: &record) { tool in
                SessionToolRecord(
                    id: tool.id,
                    name: tool.name,
                    summary: tool.summary,
                    output: tool.output,
                    content: tool.content,
                    rawInput: tool.rawInput,
                    rawOutput: tool.rawOutput,
                    state: .running,
                    isError: nil
                )
            }
        }
        records[sessionId] = record
    }

    mutating func resolveElicitation(sessionId: String, requestId: String) {
        guard var record = records[sessionId] else { return }
        record.pendingElicitations.removeAll { $0.id == requestId }
        records[sessionId] = record
    }

    mutating func remove(sessionId: String) {
        records.removeValue(forKey: sessionId)
    }

    mutating func receive(
        _ event: AgentHostServerEvent,
        timestamp: String
    ) -> [SessionStoreEffect] {
        if case .elicitationRequested(let request) = event,
           let sessionId = request.sessionId {
            guard var record = records[sessionId] else {
                return [.requestSnapshot(sessionId: sessionId)]
            }
            if let index = record.pendingElicitations.firstIndex(where: { $0.id == request.id }) {
                record.pendingElicitations[index] = request
            } else {
                record.pendingElicitations.append(request)
            }
            records[sessionId] = record
            return []
        }
        guard let identity = eventIdentity(event) else { return [] }
        guard var record = records[identity.sessionId] else {
            return [.requestSnapshot(sessionId: identity.sessionId)]
        }
        if identity.sequence <= record.lastSequence {
            return []
        }
        guard identity.sequence == record.lastSequence + 1 else {
            return [.requestSnapshot(sessionId: identity.sessionId)]
        }

        record.lastSequence = identity.sequence
        switch event {
        case .sessionStateChanged(let payload):
            if let contextUsage = payload.contextUsage {
                record.contextUsage = contextUsage
            }
            if payload.state == .running {
                record.runState = .running
                record.activeTurnId = payload.turnId
            } else {
                finishUnfinishedTools(in: &record, state: .cancelled)
                finishUnfinishedThinking(in: &record)
                record.runState = .idle
                record.activeTurnId = nil
                record.pendingApprovals = []
            }
        case .sessionMessageDelta(let payload):
            record.runState = .running
            record.activeTurnId = payload.turnId
            append(delta: payload.delta, turnId: payload.turnId, timestamp: timestamp, to: &record)
        case .sessionUserContent(let payload):
            appendUserContent(payload, timestamp: timestamp, to: &record)
        case .sessionAssistantContent(let payload):
            record.runState = .running
            record.activeTurnId = payload.turnId
            applyAssistantContent(payload, timestamp: timestamp, to: &record)
        case .sessionToolStarted(let payload):
            let existing = record.tools.first { $0.id == payload.toolCallId }
            let tool = SessionToolRecord(
                id: payload.toolCallId,
                name: payload.toolName,
                summary: payload.summary,
                output: existing?.output ?? "",
                content: payload.content ?? existing?.content ?? [],
                rawInput: payload.rawInput ?? existing?.rawInput,
                rawOutput: existing?.rawOutput,
                state: .running,
                isError: nil
            )
            replaceOrAppend(tool, in: &record.tools)
            replaceOrAppend(tool, turnId: payload.turnId, timestamp: timestamp, in: &record.transcript)
        case .sessionToolUpdated(let payload):
            let existing = record.tools.first { $0.id == payload.toolCallId }
            let tool = SessionToolRecord(
                id: payload.toolCallId,
                name: payload.toolName,
                summary: existing?.summary ?? "",
                output: payload.content == nil && payload.output.isEmpty
                    ? existing?.output ?? ""
                    : payload.output,
                content: payload.content ?? existing?.content ?? [],
                rawInput: existing?.rawInput,
                rawOutput: payload.rawOutput ?? existing?.rawOutput,
                state: .running,
                isError: nil
            )
            replaceOrAppend(tool, in: &record.tools)
            replaceOrAppend(tool, turnId: payload.turnId, timestamp: timestamp, in: &record.transcript)
        case .sessionToolCompleted(let payload):
            let existing = record.tools.first { $0.id == payload.toolCallId }
            let tool = SessionToolRecord(
                id: payload.toolCallId,
                name: payload.toolName,
                summary: existing?.summary ?? "",
                output: payload.content == nil && payload.output.isEmpty
                    ? existing?.output ?? ""
                    : payload.output,
                content: payload.content ?? existing?.content ?? [],
                rawInput: existing?.rawInput,
                rawOutput: payload.rawOutput ?? existing?.rawOutput,
                state: .completed,
                isError: payload.isError
            )
            replaceOrAppend(tool, in: &record.tools)
            replaceOrAppend(tool, turnId: payload.turnId, timestamp: timestamp, in: &record.transcript)
        case .sessionApprovalRequested(let payload):
            replaceOrAppend(payload.approval, in: &record.pendingApprovals)
            let existing = record.tools.first { $0.id == payload.toolCallId }
            let summary = existing.flatMap { $0.summary.isEmpty ? nil : $0.summary }
                ?? payload.summary
            let tool = SessionToolRecord(
                id: payload.toolCallId,
                name: payload.toolName,
                summary: summary,
                output: existing?.output ?? "",
                content: existing?.content ?? [],
                rawInput: existing?.rawInput,
                rawOutput: existing?.rawOutput,
                state: .awaitingApproval,
                isError: nil,
                approval: payload.approval
            )
            replaceOrAppend(tool, in: &record.tools)
            replaceOrAppend(tool, turnId: payload.turnId, timestamp: timestamp, in: &record.transcript)
        case .sessionError(let payload):
            finishUnfinishedTools(
                in: &record,
                state: .completed,
                errorMessage: payload.message
            )
            finishUnfinishedThinking(in: &record)
            record.runState = .failed
            record.activeTurnId = nil
            record.pendingApprovals = []
            record.errorMessage = payload.message
        case .sessionModeChanged(let payload):
            if var modes = record.acpState.modes {
                modes.currentModeId = payload.currentModeId
                record.acpState.modes = modes
            } else {
                record.acpState.modes = AgentHostACPSessionModeState(
                    currentModeId: payload.currentModeId,
                    availableModes: []
                )
            }
            if let accessMode = AgentHostAccessMode(rawValue: payload.currentModeId) {
                record.accessMode = accessMode
            }
        case .sessionConfigOptionsChanged(let payload):
            record.acpState.configOptions = payload.configOptions
            if let model = record.acpState.model {
                if record.model?.provider != model.provider || record.model?.id != model.id {
                    record.model = model
                }
            }
            record.thinkingLevel = record.acpState.thinkingLevel ?? record.thinkingLevel
            record.availableThinkingLevels = record.acpState.availableThinkingLevels
            record.modelOptions = record.acpState.modelOptions
        case .sessionInfoChanged(let payload):
            if let title = payload.title {
                record.descriptor = AgentHostSessionDescriptor(
                    id: record.descriptor.id,
                    path: record.descriptor.path,
                    cwd: record.descriptor.cwd,
                    title: title
                )
            }
            if let updatedAt = payload.updatedAt {
                record.acpState.updatedAt = updatedAt
            }
        case .sessionUsageChanged(let payload):
            record.contextUsage = AgentHostContextUsage(
                tokens: payload.used,
                contextWindow: payload.size,
                percent: payload.size > 0
                    ? Double(payload.used) / Double(payload.size) * 100
                    : nil
            )
            if let model = record.model, payload.size > 0 {
                record.model = AgentHostModel(
                    provider: model.provider,
                    id: model.id,
                    name: model.name,
                    contextWindow: payload.size,
                    maxTokens: model.maxTokens,
                    reasoning: model.reasoning,
                    supportsImages: model.supportsImages,
                    supportsFastMode: model.supportsFastMode
                )
            }
            record.acpState.cost = payload.cost
        case .sessionAvailableCommandsChanged(let payload):
            record.acpState.availableCommands = payload.availableCommands
        case .sessionPlanChanged(let payload):
            record.acpState.plan = payload.entries
        case .sessionExtensionStatusChanged(let payload):
            if let text = payload.text {
                record.acpState.extensionStatuses[payload.key] = text
            } else {
                record.acpState.extensionStatuses[payload.key] = nil
            }
        case .sessionExtensionWidgetChanged(let payload):
            record.acpState.extensionWidgets[payload.key] = payload.widget
        case .hostHello,
             .authPrompt,
             .authPromptCancelled,
             .authNotice,
             .authFinished,
             .modelsChanged,
             .elicitationRequested,
             .unknown:
            break
        }

        records[identity.sessionId] = record
        return []
    }

    private func eventIdentity(_ event: AgentHostServerEvent) -> (sessionId: String, sequence: Int)? {
        switch event {
        case .sessionStateChanged(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionMessageDelta(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionUserContent(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionAssistantContent(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionToolStarted(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionToolUpdated(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionToolCompleted(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionApprovalRequested(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionError(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionModeChanged(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionConfigOptionsChanged(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionInfoChanged(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionUsageChanged(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionAvailableCommandsChanged(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionPlanChanged(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionExtensionStatusChanged(let payload):
            return (payload.sessionId, payload.sequence)
        case .sessionExtensionWidgetChanged(let payload):
            return (payload.sessionId, payload.sequence)
        case .hostHello,
             .authPrompt,
             .authPromptCancelled,
             .authNotice,
             .authFinished,
             .modelsChanged,
             .elicitationRequested,
             .unknown:
            return nil
        }
    }

    private func append(
        delta: String,
        turnId: String,
        timestamp: String,
        to record: inout SessionRecord
    ) {
        appendTranscript(delta: delta, turnId: turnId, timestamp: timestamp, to: &record.transcript)
        let messageID = "turn:\(turnId):assistant"
        if let index = record.messages.firstIndex(where: { $0.id == messageID }) {
            let message = record.messages[index]
            let existingText = message.content.reduce(into: "") { result, content in
                if case .text(let text) = content {
                    result += text
                }
            }
            record.messages[index] = AgentHostSessionMessage(
                id: message.id,
                role: .assistant,
                content: [.text(existingText + delta)],
                timestamp: message.timestamp,
                provider: message.provider,
                model: message.model,
                stopReason: message.stopReason,
                errorMessage: message.errorMessage,
                toolCallId: nil,
                toolName: nil,
                isError: nil
            )
            return
        }

        record.messages.append(
            AgentHostSessionMessage(
                id: messageID,
                role: .assistant,
                content: [.text(delta)],
                timestamp: timestamp,
                provider: record.model?.provider,
                model: record.model?.id,
                stopReason: nil,
                errorMessage: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil
            )
        )
    }

    private func appendUserContent(
        _ payload: AgentHostSessionUserContentPayload,
        timestamp: String,
        to record: inout SessionRecord
    ) {
        let messageID = "message:\(payload.messageId):user"
        if let messageIndex = record.messages.firstIndex(where: { $0.id == messageID }) {
            let message = record.messages[messageIndex]
            let text = message.content.reduce(into: "") { result, content in
                if case .text(let value) = content { result += value }
            }
            record.messages[messageIndex] = AgentHostSessionMessage(
                id: message.id,
                role: .user,
                content: [.text(text + payload.text)],
                timestamp: message.timestamp,
                provider: nil,
                model: nil,
                stopReason: nil,
                errorMessage: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil
            )
        } else {
            record.messages.append(
                AgentHostSessionMessage(
                    id: messageID,
                    role: .user,
                    content: [.text(payload.text)],
                    timestamp: timestamp,
                    provider: nil,
                    model: nil,
                    stopReason: nil,
                    errorMessage: nil,
                    toolCallId: nil,
                    toolName: nil,
                    isError: nil
                )
            )
        }

        if let transcriptIndex = record.transcript.firstIndex(where: { $0.id == messageID }),
           let partIndex = record.transcript[transcriptIndex].parts.indices.last,
           case .text(let partID, let text) = record.transcript[transcriptIndex].parts[partIndex] {
            record.transcript[transcriptIndex].parts[partIndex] = .text(
                id: partID,
                text: text + payload.text
            )
        } else {
            record.transcript.append(
                SessionTranscriptMessage(
                    id: messageID,
                    role: .user,
                    parts: [.text(id: "\(messageID):text:0", text: payload.text)],
                    timestamp: timestamp
                )
            )
        }
    }

    private func applyAssistantContent(
        _ payload: AgentHostSessionAssistantContentPayload,
        timestamp: String,
        to record: inout SessionRecord
    ) {
        let messageID = "turn:\(payload.turnId):assistant:\(payload.generationIndex)"
        let partID = "\(messageID):content:\(payload.generationIndex):\(payload.contentIndex)"
        let messageIndex: Int
        if let existingIndex = record.transcript.firstIndex(where: { $0.id == messageID }) {
            messageIndex = existingIndex
        } else {
            record.transcript.append(
                SessionTranscriptMessage(
                    id: messageID,
                    role: .assistant,
                    parts: [],
                    timestamp: timestamp
                )
            )
            messageIndex = record.transcript.index(before: record.transcript.endIndex)
        }

        switch payload.contentType {
        case .text:
            let textIndex = record.transcript[messageIndex].parts.firstIndex { $0.id == partID }
            switch payload.phase {
            case .start:
                if textIndex == nil {
                    record.transcript[messageIndex].parts.append(.text(id: partID, text: ""))
                }
            case .delta:
                if let textIndex,
                   case .text(_, let text) = record.transcript[messageIndex].parts[textIndex] {
                    record.transcript[messageIndex].parts[textIndex] = .text(
                        id: partID,
                        text: text + (payload.delta ?? "")
                    )
                } else {
                    record.transcript[messageIndex].parts.append(
                        .text(id: partID, text: payload.delta ?? "")
                    )
                }
            case .end:
                if let content = payload.content {
                    if let textIndex {
                        record.transcript[messageIndex].parts[textIndex] = .text(
                            id: partID,
                            text: content
                        )
                    } else {
                        record.transcript[messageIndex].parts.append(.text(id: partID, text: content))
                    }
                }
            }
        case .thinking:
            let existing: SessionThinkingRecord? = record.transcript[messageIndex].parts
                .compactMap { part in
                    guard case .thinking(let thinking) = part, thinking.id == partID else {
                        return nil
                    }
                    return thinking
                }
                .first
            let state: SessionThinkingRunState = payload.phase == .end ? .completed : .running
            let text: String
            switch payload.phase {
            case .start:
                text = existing?.text ?? ""
            case .delta:
                text = (existing?.text ?? "") + (payload.delta ?? "")
            case .end:
                if let content = payload.content, !content.isEmpty {
                    text = content
                } else {
                    text = existing?.text ?? ""
                }
            }
            let thinking = SessionThinkingRecord(
                id: partID,
                text: text,
                state: state,
                redacted: existing?.redacted ?? false
            )
            if let partIndex = record.transcript[messageIndex].parts.firstIndex(where: { $0.id == partID }) {
                record.transcript[messageIndex].parts[partIndex] = .thinking(thinking)
            } else {
                record.transcript[messageIndex].parts.append(.thinking(thinking))
            }
        case .toolCall:
            guard let call = payload.toolCall else { return }
            let existing = record.tools.first { $0.id == call.id }
            let tool = SessionToolRecord(
                id: call.id,
                name: call.name,
                summary: call.argumentsSummary,
                output: existing?.output ?? "",
                content: existing?.content ?? [],
                rawInput: existing?.rawInput,
                rawOutput: existing?.rawOutput,
                state: existing?.state ?? .running,
                isError: existing?.isError,
                approval: existing?.approval
            )
            replaceOrAppend(tool, in: &record.tools)
            replaceOrAppend(
                tool,
                turnId: payload.turnId,
                timestamp: timestamp,
                in: &record.transcript
            )
        }
    }

    private func replaceOrAppend(_ tool: SessionToolRecord, in tools: inout [SessionToolRecord]) {
        if let index = tools.firstIndex(where: { $0.id == tool.id }) {
            tools[index] = tool
        } else {
            tools.append(tool)
        }
    }

    private func updateTool(
        toolCallId: String,
        in record: inout SessionRecord,
        transform: (SessionToolRecord) -> SessionToolRecord
    ) {
        if let index = record.tools.firstIndex(where: { $0.id == toolCallId }) {
            record.tools[index] = transform(record.tools[index])
        }
        for messageIndex in record.transcript.indices {
            for partIndex in record.transcript[messageIndex].parts.indices {
                guard case .tool(let tool) = record.transcript[messageIndex].parts[partIndex],
                      tool.id == toolCallId else { continue }
                record.transcript[messageIndex].parts[partIndex] = .tool(transform(tool))
            }
        }
    }

    private func finishUnfinishedTools(
        in record: inout SessionRecord,
        state: SessionToolRunState,
        errorMessage: String? = nil
    ) {
        let toolCallIds = record.tools
            .filter { !$0.state.isTerminal }
            .map(\.id)
        for toolCallId in toolCallIds {
            updateTool(toolCallId: toolCallId, in: &record) { tool in
                let output: String
                if let errorMessage {
                    output = tool.output.isEmpty
                        ? errorMessage
                        : "\(tool.output)\n\(errorMessage)"
                } else {
                    output = tool.output
                }
                return SessionToolRecord(
                    id: tool.id,
                    name: tool.name,
                    summary: tool.summary,
                    output: output,
                    content: tool.content,
                    rawInput: tool.rawInput,
                    rawOutput: tool.rawOutput,
                    state: state,
                    isError: errorMessage == nil ? tool.isError : true
                )
            }
        }
    }

    private func finishUnfinishedThinking(in record: inout SessionRecord) {
        for messageIndex in record.transcript.indices {
            for partIndex in record.transcript[messageIndex].parts.indices {
                guard case .thinking(let thinking) = record.transcript[messageIndex].parts[partIndex],
                      thinking.state == .running else { continue }
                record.transcript[messageIndex].parts[partIndex] = .thinking(
                    SessionThinkingRecord(
                        id: thinking.id,
                        text: thinking.text,
                        state: .completed,
                        redacted: thinking.redacted
                    )
                )
            }
        }
    }

    private func appendTranscript(
        delta: String,
        turnId: String,
        timestamp: String,
        to transcript: inout [SessionTranscriptMessage]
    ) {
        let messageID = "turn:\(turnId):assistant"
        if let messageIndex = transcript.firstIndex(where: { $0.id == messageID }) {
            if let lastIndex = transcript[messageIndex].parts.indices.last,
               case .text(let id, let text) = transcript[messageIndex].parts[lastIndex] {
                transcript[messageIndex].parts[lastIndex] = .text(id: id, text: text + delta)
            } else {
                let partID = "\(messageID):text:\(transcript[messageIndex].parts.count)"
                transcript[messageIndex].parts.append(.text(id: partID, text: delta))
            }
            return
        }

        transcript.append(
            SessionTranscriptMessage(
                id: messageID,
                role: .assistant,
                parts: [.text(id: "\(messageID):text:0", text: delta)],
                timestamp: timestamp
            )
        )
    }

    private func replaceOrAppend(
        _ tool: SessionToolRecord,
        turnId: String,
        timestamp: String,
        in transcript: inout [SessionTranscriptMessage]
    ) {
        for messageIndex in transcript.indices {
            if let partIndex = transcript[messageIndex].parts.firstIndex(where: { part in
                guard case .tool(let existing) = part else { return false }
                return existing.id == tool.id
            }) {
                transcript[messageIndex].parts[partIndex] = .tool(tool)
                return
            }
        }

        let messageID = "turn:\(turnId):assistant"
        let messageIndex = transcript.indices.reversed().first { index in
            transcript[index].role == .assistant
                && (
                    transcript[index].id == messageID
                        || transcript[index].id.hasPrefix("\(messageID):")
                )
        }
        if let messageIndex {
            transcript[messageIndex].parts.append(.tool(tool))
        } else {
            transcript.append(
                SessionTranscriptMessage(
                    id: messageID,
                    role: .assistant,
                    parts: [.tool(tool)],
                    timestamp: timestamp
                )
            )
        }
    }

    private static func makeTranscript(
        from messages: [AgentHostSessionMessage],
        pendingApprovals: [AgentHostApprovalRequest],
        sessionState: AgentHostSessionRunState
    ) -> [SessionTranscriptMessage] {
        let toolResults = Dictionary(
            messages.compactMap { message -> (String, AgentHostSessionMessage)? in
                guard message.role == .tool, let toolCallId = message.toolCallId else { return nil }
                return (toolCallId, message)
            },
            uniquingKeysWith: { _, latest in latest }
        )

        func parts(for message: AgentHostSessionMessage) -> [SessionTranscriptPart] {
            message.content.enumerated().map { index, content -> SessionTranscriptPart in
                let partID = "\(message.id):part:\(index)"
                switch content {
                case .text(let text):
                    return .text(id: partID, text: text)
                case .skill(let name):
                    return .skill(SessionSkillRecord(id: partID, name: name))
                case .thinking(let text, let redacted):
                    return .thinking(
                        SessionThinkingRecord(
                            id: partID,
                            text: text,
                            state: .completed,
                            redacted: redacted
                        )
                    )
                case .image(let mimeType, let data):
                    return .image(id: partID, mimeType: mimeType, data: data)
                case .toolCall(let id, let name, let argumentsSummary):
                    let result = toolResults[id]
                    return .tool(
                        SessionToolRecord(
                            id: id,
                            name: name,
                            summary: argumentsSummary,
                            output: result.map(toolOutput) ?? "",
                            outputTruncated: result?.toolOutputTruncated == true,
                            outputByteCount: result?.toolOutputBytes,
                            state: result == nil
                                ? (sessionState == .running ? .running : .cancelled)
                                : .completed,
                            isError: result?.isError
                        )
                    )
                }
            }
        }

        var transcript: [SessionTranscriptMessage] = []
        for message in messages {
            if message.role == .tool, message.toolCallId != nil {
                continue
            }

            let messageParts = parts(for: message)
            guard !messageParts.isEmpty else { continue }
            transcript.append(
                SessionTranscriptMessage(
                    id: message.id,
                    role: message.role,
                    parts: messageParts,
                    timestamp: message.timestamp
                )
            )
        }

        for approval in pendingApprovals {
            var didAttach = false
            for messageIndex in transcript.indices {
                guard let partIndex = transcript[messageIndex].parts.firstIndex(where: { part in
                    guard case .tool(let tool) = part else { return false }
                    return tool.id == approval.toolCallId
                }), case .tool(let tool) = transcript[messageIndex].parts[partIndex] else {
                    continue
                }
                transcript[messageIndex].parts[partIndex] = .tool(
                    SessionToolRecord(
                        id: tool.id,
                        name: tool.name,
                        summary: tool.summary,
                        output: tool.output,
                        content: tool.content,
                        rawInput: tool.rawInput,
                        rawOutput: tool.rawOutput,
                        outputTruncated: tool.outputTruncated,
                        outputByteCount: tool.outputByteCount,
                        state: .awaitingApproval,
                        isError: nil,
                        approval: approval
                    )
                )
                didAttach = true
                break
            }
            if !didAttach {
                transcript.append(
                    SessionTranscriptMessage(
                        id: "approval:\(approval.id):assistant",
                        role: .assistant,
                        parts: [
                            .tool(
                                SessionToolRecord(
                                    id: approval.toolCallId,
                                    name: approval.toolName,
                                    summary: approval.summary,
                                    state: .awaitingApproval,
                                    isError: nil,
                                    approval: approval
                                )
                            )
                        ],
                        timestamp: ""
                    )
                )
            }
        }
        return transcript
    }

    private static func toolOutput(_ message: AgentHostSessionMessage) -> String {
        message.content.map { content in
            switch content {
            case .text(let text):
                return text
            case .skill:
                return ""
            case .thinking:
                return ""
            case .image(let mimeType, _):
                return "[image: \(mimeType)]"
            case .toolCall(_, let name, let argumentsSummary):
                return "\(name) \(argumentsSummary)"
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private func replaceOrAppend(
        _ approval: AgentHostApprovalRequest,
        in approvals: inout [AgentHostApprovalRequest]
    ) {
        if let index = approvals.firstIndex(where: { $0.id == approval.id }) {
            approvals[index] = approval
        } else {
            approvals.append(approval)
        }
    }

    private func makeSessionTitle(from text: String) -> String? {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(40))
    }

    private func skillInvocation(in text: String) -> (name: String, userText: String)? {
        guard text.hasPrefix("/skill:") else { return nil }
        let nameStart = text.index(text.startIndex, offsetBy: "/skill:".count)
        let nameEnd = text[nameStart...].firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
        let name = String(text[nameStart..<nameEnd])
        guard !name.isEmpty else { return nil }
        return (
            name,
            String(text[nameEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum SessionStoreConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(generation: Int)
    case failed(String)
}

enum SessionStoreError: Error {
    case sessionNotOpen(String)
    case sessionBusy(String)
    case historyChanged(String)
    case downloadsDirectoryUnavailable
    case exportedReportMismatch(String)
    case exportedReportMissing(String)
    case cannotOpenExportedReport(String)
}

enum SessionHTMLReportDestination {
    static func makeURL(
        for summary: AgentHostSessionSummary,
        downloadsDirectory: URL,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )

        let title = sanitizedComponent(summary.title, fallback: "pi-work-session", limit: 60)
        let sessionID = sanitizedComponent(summary.id, fallback: "session", limit: 8)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(title)-\(formatter.string(from: now))-\(sessionID)"

        var suffix = 1
        var candidate = downloadsDirectory.appendingPathComponent("\(stem).html")
        while fileManager.fileExists(atPath: candidate.path) {
            suffix += 1
            candidate = downloadsDirectory.appendingPathComponent("\(stem)-\(suffix).html")
        }
        return candidate
    }

    private static func sanitizedComponent(
        _ value: String,
        fallback: String,
        limit: Int
    ) -> String {
        let parts = value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let sanitized = parts.joined(separator: "-")
        return sanitized.isEmpty ? fallback : String(sanitized.prefix(limit))
    }
}

enum SessionCachePolicy {
    static func evictionCandidates(
        recency: [String],
        protectedSessionIDs: Set<String>,
        runningSessionIDs: Set<String>,
        maximumCount: Int
    ) -> [String] {
        let removalCount = max(0, recency.count - maximumCount)
        guard removalCount > 0 else { return [] }
        return Array(
            recency.lazy
                .filter { !protectedSessionIDs.contains($0) && !runningSessionIDs.contains($0) }
                .prefix(removalCount)
        )
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var records: [String: SessionRecord] = [:]
    @Published private(set) var chatSessions: [AgentHostSessionSummary] = []
    @Published private(set) var workSessionsByProjectPath: [String: [AgentHostSessionSummary]] = [:]
    @Published private(set) var availableModels: [AgentHostModel] = []
    @Published private(set) var selectedChatSessionId: String?
    @Published private(set) var selectedWorkSessionIdByProjectPath: [String: String] = [:]
    @Published private(set) var connectionState: SessionStoreConnectionState = .disconnected
    @Published private(set) var pendingElicitations: [AgentHostACPElicitationRequest] = []

    private let service: any AgentHostServicing
    private let now: () -> Date
    private let maximumCachedSessionCount: Int
    private let performanceTracer: SessionOpenPerformanceTracer
    private var reducer = SessionStoreReducer()
    private var eventTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var didBeginObserving = false
    private var didStart = false
    private var isStopped = false
    private var piWorkCapabilities: Set<AgentHostPiWorkCapability> = []
    private var supportsACPImagePrompts = false
    private var selectedSessionIds: Set<String> = []
    private var snapshotRequestsInFlight: Set<String> = []
    private var historyRequestsInFlight: Set<String> = []
    private var sessionRecency: [String] = []

    init(
        service: any AgentHostServicing,
        now: @escaping () -> Date = Date.init,
        maximumCachedSessionCount: Int = 6,
        performanceTracer: SessionOpenPerformanceTracer? = nil
    ) {
        self.service = service
        self.now = now
        self.maximumCachedSessionCount = maximumCachedSessionCount
        self.performanceTracer = performanceTracer ?? SessionOpenPerformanceTracer()
    }

    func beginSessionOpenPerformanceTrace(
        sessionID: String,
        profile: AgentHostSessionProfile
    ) -> UUID {
        performanceTracer.begin(sessionID: sessionID, profile: profile)
    }

    func markSessionOpenPerformanceTrace(
        _ traceID: UUID,
        stage: SessionOpenPerformanceStage
    ) {
        performanceTracer.mark(traceID: traceID, stage: stage)
    }

    func markActiveSessionOpenPerformance(
        sessionID: String,
        stage: SessionOpenPerformanceStage
    ) {
        performanceTracer.markActive(sessionID: sessionID, stage: stage)
    }

    func finishActiveSessionOpenPerformance(sessionID: String) {
        performanceTracer.finishActive(
            sessionID: sessionID,
            transcriptCount: records[sessionID]?.transcript.count
        )
    }

    func cancelSessionOpenPerformanceTrace(_ traceID: UUID) {
        performanceTracer.cancel(traceID: traceID)
    }

    func failSessionOpenPerformanceTrace(_ traceID: UUID) {
        performanceTracer.fail(traceID: traceID)
    }

    func start() async throws {
        if didStart { return }
        guard !isStopped else { throw AgentHostServiceError.stopped }
        didStart = true
        connectionState = .connecting
        await beginObserving()
        do {
            let hello = try await service.start()
            piWorkCapabilities = hello.piWorkCapabilities
            supportsACPImagePrompts = hello.acpCapabilities.promptImages
        } catch {
            didStart = false
            connectionState = .failed(String(describing: error))
            throw error
        }
    }

    func bootstrap(
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile
    ) async throws {
        try await start()
        async let listedSessions = service.listSessions(
            cwd: cwd,
            sessionDirectory: sessionDirectory,
            requestID: UUID().uuidString
        )
        var models: [AgentHostModel] = []
        if supportsPiWorkCapability(.modelsList) {
            do {
                models = try await service.listModels(requestID: UUID().uuidString)
            } catch where Self.isMethodNotFound(error) {
                models = []
            }
        }
        let sessions = try await listedSessions
        let sortedSessions = sessions.sorted { lhs, rhs in
            lhs.modifiedAt == rhs.modifiedAt ? lhs.id < rhs.id : lhs.modifiedAt > rhs.modifiedAt
        }
        availableModels = models
        if profile == .chat {
            chatSessions = sortedSessions
        } else {
            workSessionsByProjectPath[cwd] = sortedSessions
        }
    }

    func openSession(
        _ summary: AgentHostSessionSummary,
        profile: AgentHostSessionProfile,
        sessionDirectory: String?,
        selectSession: Bool = true,
        performanceTraceID: UUID? = nil
    ) async throws {
        var provisionalSessionID: String?
        do {
            try await start()
            if let performanceTraceID {
                performanceTracer.mark(traceID: performanceTraceID, stage: .hostReady)
            }
            if let record = records[summary.id] {
                touchSession(summary.id)
                if let performanceTraceID {
                    performanceTracer.mark(traceID: performanceTraceID, stage: .cacheHit)
                }
                if selectSession {
                    select(summary.id, profile: record.profile, cwd: record.descriptor.cwd)
                    if let performanceTraceID {
                        performanceTracer.mark(
                            traceID: performanceTraceID,
                            stage: .selectionCommitted
                        )
                    }
                }
                return
            }
            reducer.apply(
                SessionStoreReducer.project(
                    summary: summary,
                    profile: profile,
                    sessionDirectory: sessionDirectory
                )
            )
            provisionalSessionID = summary.id
            let openResult: AgentHostSessionOpenResult
            do {
                openResult = try await service.openSession(
                    sessionId: summary.id,
                    cwd: summary.cwd,
                    sessionDirectory: sessionDirectory,
                    profile: profile,
                    requestID: UUID().uuidString
                )
            } catch AgentHostClientError.requestTimedOut {
                openResult = try await service.openSession(
                    sessionId: summary.id,
                    cwd: summary.cwd,
                    sessionDirectory: sessionDirectory,
                    profile: profile,
                    requestID: UUID().uuidString
                )
            }
            if let performanceTraceID {
                performanceTracer.mark(traceID: performanceTraceID, stage: .openRPCCompleted)
            }
            var snapshot: AgentHostSessionSnapshotResult?
            if supportsPiWorkCapability(.sessionSnapshot) {
                do {
                    snapshot = try await service.snapshot(
                        sessionId: summary.id,
                        requestID: UUID().uuidString
                    )
                } catch where Self.isMethodNotFound(error) {
                    snapshot = nil
                }
            }
            if let performanceTraceID {
                performanceTracer.mark(
                    traceID: performanceTraceID,
                    stage: .snapshotCompleted,
                    messageCount: snapshot?.messages.count,
                    hasEarlierMessages: snapshot?.history?.hasMore
                )
            }
            if let snapshot {
                reducer.apply(
                    await project(
                        snapshot: snapshot,
                        profile: profile,
                        sessionDirectory: sessionDirectory
                    )
                )
            } else {
                reducer.applyACPState(
                    normalizedACPState(openResult.acpState),
                    sessionId: summary.id
                )
            }
            guard let projectedRecord = reducer.records[summary.id] else {
                throw SessionStoreError.sessionNotOpen(summary.id)
            }
            mergeAvailableModels(normalizedACPState(openResult.acpState).availableModels)
            if let performanceTraceID {
                performanceTracer.mark(
                    traceID: performanceTraceID,
                    stage: .projectionCompleted,
                    transcriptCount: projectedRecord.transcript.count
                )
            }
            touchSession(projectedRecord.id)
            if selectSession {
                select(
                    projectedRecord.id,
                    profile: profile,
                    cwd: projectedRecord.descriptor.cwd
                )
                if let performanceTraceID {
                    performanceTracer.mark(
                        traceID: performanceTraceID,
                        stage: .selectionCommitted
                    )
                }
            }
            publishReducerState()
            if let performanceTraceID {
                performanceTracer.mark(traceID: performanceTraceID, stage: .storePublished)
            }
            await trimSessionCache(protecting: [projectedRecord.id])
            if let performanceTraceID {
                performanceTracer.mark(traceID: performanceTraceID, stage: .cacheTrimCompleted)
            }
            provisionalSessionID = nil
        } catch {
            if let provisionalSessionID {
                reducer.remove(sessionId: provisionalSessionID)
                publishReducerState()
            }
            if let performanceTraceID {
                performanceTracer.fail(traceID: performanceTraceID)
            }
            throw error
        }
    }

    func exportHTMLReport(
        _ summary: AgentHostSessionSummary,
        profile: AgentHostSessionProfile,
        sessionDirectory: String?,
        downloadsDirectory: URL? = nil
    ) async throws -> URL {
        try await start()
        guard supportsPiWorkCapability(.sessionExportHTML) else {
            throw AgentHostServiceError.missingPiWorkCapability(.sessionExportHTML)
        }
        let destinationDirectory: URL
        if let downloadsDirectory {
            destinationDirectory = downloadsDirectory
        } else if let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first {
            destinationDirectory = downloadsDirectory
        } else {
            throw SessionStoreError.downloadsDirectoryUnavailable
        }
        let outputURL = try SessionHTMLReportDestination.makeURL(
            for: summary,
            downloadsDirectory: destinationDirectory,
            now: now()
        )
        let result = try await service.exportHTML(
            sessionId: summary.id,
            path: summary.path,
            sessionDirectory: sessionDirectory,
            profile: profile,
            outputPath: outputURL.path,
            requestID: UUID().uuidString
        )
        guard result.sessionId == summary.id else {
            throw SessionStoreError.exportedReportMismatch(summary.id)
        }
        let exportedURL = URL(fileURLWithPath: result.path).standardizedFileURL
        guard exportedURL == outputURL.standardizedFileURL else {
            throw SessionStoreError.exportedReportMismatch(summary.id)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: exportedURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw SessionStoreError.exportedReportMissing(exportedURL.path)
        }
        return exportedURL
    }

    func selectOpenSession(
        sessionId: String,
        profile: AgentHostSessionProfile,
        cwd: String
    ) throws {
        guard let record = records[sessionId],
              record.profile == profile,
              record.descriptor.cwd == cwd else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        touchSession(sessionId)
        select(sessionId, profile: profile, cwd: cwd)
    }

    func loadEarlierMessages(sessionId: String) async throws -> Int {
        guard let record = reducer.records[sessionId] else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        guard record.hasEarlierMessages, let cursor = record.historyCursor else { return 0 }
        guard supportsPiWorkCapability(.sessionTranscriptPage) else {
            throw AgentHostServiceError.missingPiWorkCapability(.sessionTranscriptPage)
        }
        guard historyRequestsInFlight.insert(sessionId).inserted else { return 0 }
        defer { historyRequestsInFlight.remove(sessionId) }

        let page = try await service.transcriptPage(
            sessionId: sessionId,
            cursor: cursor,
            limit: TranscriptWindow.batchSize,
            requestID: UUID().uuidString
        )
        guard reducer.records[sessionId]?.historyRevision == page.revision else {
            throw SessionStoreError.historyChanged(sessionId)
        }
        let loadedCount = reducer.prependTranscriptPage(page)
        publishReducerState()
        return loadedCount
    }

    @discardableResult
    func createDraft(
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        selectSession: Bool = true
    ) async throws -> SessionRecord {
        try await start()
        let result = try await service.createDraft(
            cwd: cwd,
            sessionDirectory: sessionDirectory,
            profile: profile,
            requestID: UUID().uuidString
        )
        let summary = result.session
        let acpState = normalizedACPState(result.acpState)
        let projectedRecord: SessionRecord
        if supportsPiWorkCapability(.sessionSnapshot) {
            do {
                let snapshot = try await service.snapshot(
                    sessionId: summary.id,
                    requestID: UUID().uuidString
                )
                projectedRecord = await project(
                    snapshot: snapshot,
                    profile: profile,
                    sessionDirectory: sessionDirectory
                )
            } catch where Self.isMethodNotFound(error) {
                projectedRecord = SessionStoreReducer.project(
                    summary: summary,
                    profile: profile,
                    sessionDirectory: sessionDirectory,
                    acpState: acpState
                )
            }
        } else {
            projectedRecord = SessionStoreReducer.project(
                summary: summary,
                profile: profile,
                sessionDirectory: sessionDirectory,
                acpState: acpState
            )
        }
        mergeAvailableModels(acpState.availableModels)
        reducer.apply(projectedRecord)
        touchSession(projectedRecord.id)
        appendSummaryIfNeeded(summary, profile: profile, cwd: cwd)
        if selectSession {
            select(summary.id, profile: profile, cwd: cwd)
        }
        publishReducerState()
        await trimSessionCache(protecting: [projectedRecord.id])
        guard let record = records[summary.id] else {
            throw SessionStoreError.sessionNotOpen(summary.id)
        }
        return record
    }

    func slashCommands(sessionId: String) async throws -> [AgentHostSlashCommand] {
        guard let record = records[sessionId] else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        if let commands = record.acpState.availableCommands {
            return commands.map {
                AgentHostSlashCommand(
                    name: $0.name,
                    description: $0.description,
                    source: .agent
                )
            }
        }
        guard supportsPiWorkCapability(.sessionCommands) else { return [] }
        return try await service.listSlashCommands(
            sessionId: sessionId,
            requestID: UUID().uuidString
        )
    }

    func toolOutput(sessionId: String, toolCallId: String) async throws -> String {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        guard supportsPiWorkCapability(.sessionToolOutput) else {
            throw AgentHostServiceError.missingPiWorkCapability(.sessionToolOutput)
        }
        return try await service.toolOutput(
            sessionId: sessionId,
            toolCallId: toolCallId,
            requestID: UUID().uuidString
        ).output
    }

    func gitBranches(cwd: String) async throws -> AgentHostGitBranchesResult {
        try await start()
        guard supportsPiWorkCapability(.gitBranches) else { return .unavailable }
        return try await service.gitBranches(
            cwd: cwd,
            requestID: UUID().uuidString
        )
    }

    func setGitBranch(_ branch: String, sessionId: String) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        guard supportsPiWorkCapability(.sessionSetGitBranch) else {
            throw AgentHostServiceError.missingPiWorkCapability(.sessionSetGitBranch)
        }
        let result = try await service.setGitBranch(
            sessionId: sessionId,
            branch: branch,
            requestID: UUID().uuidString
        )
        reducer.setGitBranch(sessionId: result.sessionId, branch: result.branch)
        publishReducerState()
    }

    @discardableResult
    func submitPrompt(
        sessionId: String,
        text: String,
        images: [AgentHostPromptImage] = []
    ) async throws -> String {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        let turnId = UUID().uuidString
        let effects = reducer.submitPrompt(
            sessionId: sessionId,
            turnId: turnId,
            text: text,
            images: images,
            timestamp: Self.timestamp(from: now())
        )
        guard reducer.records[sessionId]?.activeTurnId == turnId else {
            throw SessionStoreError.sessionBusy(sessionId)
        }
        publishReducerState()

        do {
            let accepted = try await service.prompt(
                sessionId: sessionId,
                turnId: turnId,
                text: text,
                images: images,
                requestID: UUID().uuidString
            )
            reducer.promptCompleted(sessionId: accepted.sessionId, turnId: accepted.turnId)
            publishReducerState()
            await process(effects)
            return turnId
        } catch {
            reducer.promptFailed(
                sessionId: sessionId,
                turnId: turnId,
                message: String(describing: error)
            )
            for case .renameSession(let effectSessionId, let title) in effects {
                reducer.revertGeneratedTitle(sessionId: effectSessionId, title: title)
            }
            publishReducerState()
            throw error
        }
    }

    func abortSession(sessionId: String) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        reducer.requestAbort(sessionId: sessionId)
        guard reducer.records[sessionId]?.runState == .stopping else {
            throw SessionStoreError.sessionBusy(sessionId)
        }
        publishReducerState()
        do {
            _ = try await service.abort(
                sessionId: sessionId,
                requestID: UUID().uuidString
            )
        } catch {
            await repairSnapshot(sessionId: sessionId)
            throw error
        }
    }

    func selectModel(_ model: AgentHostModel, sessionId: String) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        let result = try await service.setModel(
            sessionId: sessionId,
            provider: model.provider,
            modelId: model.id,
            requestID: UUID().uuidString
        )
        reducer.selectModel(
            sessionId: sessionId,
            model: model,
            contextUsage: result.contextUsage,
            thinkingLevel: result.thinkingLevel,
            availableThinkingLevels: result.availableThinkingLevels,
            modelOptions: result.modelOptions
        )
        publishReducerState()
    }

    func selectModelOption(
        _ option: AgentHostModelOption,
        enabled: Bool,
        sessionId: String
    ) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        let result = try await service.setModelOption(
            sessionId: sessionId,
            option: option,
            enabled: enabled,
            requestID: UUID().uuidString
        )
        reducer.selectModelOption(
            sessionId: result.sessionId,
            model: records[sessionId]?.model ?? result.model,
            contextUsage: result.contextUsage,
            modelOptions: result.modelOptions
        )
        publishReducerState()
    }

    func selectThinkingLevel(
        _ thinkingLevel: AgentHostThinkingLevel,
        sessionId: String
    ) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        let result = try await service.setThinkingLevel(
            sessionId: sessionId,
            thinkingLevel: thinkingLevel,
            requestID: UUID().uuidString
        )
        reducer.selectThinkingLevel(
            sessionId: sessionId,
            thinkingLevel: result.thinkingLevel,
            availableThinkingLevels: result.availableThinkingLevels
        )
        publishReducerState()
    }

    func selectConfigOption(
        _ option: AgentHostACPSetConfigOptionResult.ConfigOption,
        value: AgentHostACPSetConfigOptionResult.ConfigOption.Value,
        sessionId: String
    ) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        let result = try await service.setConfigOption(
            sessionId: sessionId,
            configId: option.id,
            value: value,
            requestID: UUID().uuidString
        )
        reducer.applyACPState(normalizedACPState(result.acpState), sessionId: sessionId)
        publishReducerState()
    }

    func selectSessionMode(_ modeId: String, sessionId: String) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        try await service.setSessionMode(
            sessionId: sessionId,
            modeId: modeId,
            requestID: UUID().uuidString
        )
        reducer.selectSessionMode(sessionId: sessionId, modeId: modeId)
        publishReducerState()
    }

    func selectAccessMode(
        _ accessMode: AgentHostAccessMode,
        sessionId: String
    ) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        let result = try await service.setAccessMode(
            sessionId: sessionId,
            accessMode: accessMode,
            requestID: UUID().uuidString
        )
        reducer.selectAccessMode(
            sessionId: result.sessionId,
            accessMode: result.accessMode
        )
        publishReducerState()
    }

    func resolveApproval(
        sessionId: String,
        requestId: String,
        decision: AgentHostApprovalDecision
    ) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        let result = try await service.resolveApproval(
            sessionId: sessionId,
            requestId: requestId,
            decision: decision,
            requestID: UUID().uuidString
        )
        reducer.resolveApproval(
            sessionId: result.sessionId,
            requestId: result.requestId
        )
        publishReducerState()
    }

    func resolveElicitation(
        sessionId: String?,
        requestId: String,
        response: AgentHostACPElicitationResponse
    ) async throws {
        if let sessionId, records[sessionId] == nil {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        try await service.resolveElicitation(
            sessionId: sessionId,
            requestId: requestId,
            response: response,
            requestID: UUID().uuidString
        )
        if let sessionId {
            reducer.resolveElicitation(sessionId: sessionId, requestId: requestId)
            publishReducerState()
        } else {
            pendingElicitations.removeAll { $0.id == requestId }
        }
    }

    func closeSession(sessionId: String) async throws {
        guard records[sessionId] != nil else {
            throw SessionStoreError.sessionNotOpen(sessionId)
        }
        _ = try await service.closeSession(
            sessionId: sessionId,
            requestID: UUID().uuidString
        )
        reducer.remove(sessionId: sessionId)
        selectedSessionIds.remove(sessionId)
        if selectedChatSessionId == sessionId {
            selectedChatSessionId = nil
        }
        selectedWorkSessionIdByProjectPath = selectedWorkSessionIdByProjectPath.filter {
            $0.value != sessionId
        }
        publishReducerState()
    }

    func deleteSession(
        _ summary: AgentHostSessionSummary,
        profile: AgentHostSessionProfile,
        sessionDirectory: String?
    ) async throws {
        try await start()
        _ = try await service.deleteSession(
            sessionId: summary.id,
            cwd: summary.cwd,
            sessionDirectory: sessionDirectory,
            requestID: UUID().uuidString
        )
        reducer.remove(sessionId: summary.id)
        selectedSessionIds.remove(summary.id)
        if profile == .chat {
            chatSessions.removeAll { $0.id == summary.id }
            if selectedChatSessionId == summary.id {
                selectedChatSessionId = nil
            }
        } else {
            workSessionsByProjectPath[summary.cwd]?.removeAll { $0.id == summary.id }
            if selectedWorkSessionIdByProjectPath[summary.cwd] == summary.id {
                selectedWorkSessionIdByProjectPath[summary.cwd] = nil
            }
        }
        publishReducerState()
    }

    func deleteWorkSessions(
        cwd: String,
        sessionDirectory: String?
    ) async throws {
        try await start()
        let sessions = try await service.listSessions(
            cwd: cwd,
            sessionDirectory: sessionDirectory,
            requestID: UUID().uuidString
        )
        for session in sessions where session.cwd == cwd {
            try await deleteSession(
                session,
                profile: .work,
                sessionDirectory: sessionDirectory
            )
        }
        workSessionsByProjectPath[cwd] = nil
        selectedWorkSessionIdByProjectPath[cwd] = nil
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        eventTask?.cancel()
        lifecycleTask?.cancel()
        eventTask = nil
        lifecycleTask = nil
        await service.stop()
        connectionState = .disconnected
    }

    private func beginObserving() async {
        guard !didBeginObserving else { return }
        didBeginObserving = true
        let events = await service.events()
        let lifecycles = await service.lifecycleEvents()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
        lifecycleTask = Task { [weak self] in
            for await lifecycle in lifecycles {
                guard !Task.isCancelled else { return }
                await self?.receive(lifecycle)
            }
        }
    }

    private func receive(_ event: AgentHostServerEvent) async {
        if case .modelsChanged = event, supportsPiWorkCapability(.modelsList) {
            if let models = try? await service.listModels(requestID: UUID().uuidString) {
                availableModels = models
            }
            return
        }
        if case .elicitationRequested(let request) = event, request.sessionId == nil {
            if let index = pendingElicitations.firstIndex(where: { $0.id == request.id }) {
                pendingElicitations[index] = request
            } else {
                pendingElicitations.append(request)
            }
            return
        }
        let effects = reducer.receive(event, timestamp: Self.timestamp(from: now()))
        if case .sessionInfoChanged(let payload) = event,
           let title = payload.title {
            updateSummaryTitle(sessionId: payload.sessionId, title: title)
        }
        if case .sessionConfigOptionsChanged(let payload) = event {
            mergeAvailableModels(
                normalizedACPState(
                    AgentHostACPSessionState(configOptions: payload.configOptions)
                ).availableModels
            )
        }
        publishReducerState()
        await process(effects)
    }

    private func receive(_ event: AgentHostServiceLifecycleEvent) async {
        switch event {
        case .connected(let generation, let hello):
            piWorkCapabilities = hello.piWorkCapabilities
            supportsACPImagePrompts = hello.acpCapabilities.promptImages
            connectionState = .connected(generation: generation)
        case .disconnected:
            connectionState = .disconnected
        case .restarted(let generation, let hello):
            piWorkCapabilities = hello.piWorkCapabilities
            supportsACPImagePrompts = hello.acpCapabilities.promptImages
            connectionState = .connected(generation: generation)
            await recoverSelectedSessions()
        }
    }

    private func process(_ effects: [SessionStoreEffect]) async {
        for effect in effects {
            switch effect {
            case .requestSnapshot(let sessionId):
                await repairSnapshot(sessionId: sessionId)
            case .renameSession(let sessionId, let title):
                guard supportsPiWorkCapability(.sessionRename) else { continue }
                do {
                    _ = try await service.renameSession(
                        sessionId: sessionId,
                        title: title,
                        requestID: UUID().uuidString
                    )
                    updateSummaryTitle(sessionId: sessionId, title: title)
                } catch {
                    // The optimistic local title remains useful; a later list refresh reconciles it.
                }
            }
        }
    }

    private func repairSnapshot(sessionId: String) async {
        guard supportsPiWorkCapability(.sessionSnapshot),
              let record = reducer.records[sessionId],
              snapshotRequestsInFlight.insert(sessionId).inserted else {
            return
        }
        defer { snapshotRequestsInFlight.remove(sessionId) }
        do {
            let snapshot = try await service.snapshot(
                sessionId: sessionId,
                requestID: UUID().uuidString
            )
            let projectedRecord = await project(
                snapshot: snapshot,
                profile: record.profile,
                sessionDirectory: record.sessionDirectory
            )
            if reducer.records[sessionId]?.lastSequence ?? 0 <= projectedRecord.lastSequence {
                reducer.apply(projectedRecord)
                publishReducerState()
            }
        } catch {
            // Connection lifecycle recovery will retry selected sessions after a Host restart.
        }
    }

    private func recoverSelectedSessions() async {
        let recoverable = reducer.records.values.filter { record in
            selectedSessionIds.contains(record.id)
                || record.runState == .running
                || record.runState == .submitting
                || record.runState == .stopping
        }
        for record in recoverable {
            do {
                let result = try await service.openSession(
                    sessionId: record.id,
                    cwd: record.descriptor.cwd,
                    sessionDirectory: record.sessionDirectory,
                    profile: record.profile,
                    requestID: UUID().uuidString
                )
                if let modeId = record.acpState.modes?.currentModeId {
                    try await service.setSessionMode(
                        sessionId: record.id,
                        modeId: modeId,
                        requestID: UUID().uuidString
                    )
                } else if record.profile == .work {
                    _ = try await service.setAccessMode(
                        sessionId: record.id,
                        accessMode: record.accessMode,
                        requestID: UUID().uuidString
                    )
                }
                if supportsPiWorkCapability(.sessionSnapshot) {
                    let snapshot = try await service.snapshot(
                        sessionId: record.id,
                        requestID: UUID().uuidString
                    )
                    let projectedRecord = await project(
                        snapshot: snapshot,
                        profile: record.profile,
                        sessionDirectory: record.sessionDirectory
                    )
                    reducer.apply(projectedRecord)
                } else {
                    reducer.applyACPState(
                        normalizedACPState(result.acpState),
                        sessionId: record.id
                    )
                }
                publishReducerState()
            } catch {
                // Keep the last projection visible; the UI can offer an explicit retry.
            }
        }
    }

    private func select(
        _ sessionId: String,
        profile: AgentHostSessionProfile,
        cwd: String
    ) {
        selectedSessionIds.insert(sessionId)
        if profile == .chat {
            selectedChatSessionId = sessionId
        } else {
            selectedWorkSessionIdByProjectPath[cwd] = sessionId
        }
    }

    private func appendSummaryIfNeeded(
        _ summary: AgentHostSessionSummary,
        profile: AgentHostSessionProfile,
        cwd: String
    ) {
        if profile == .chat {
            if !chatSessions.contains(where: { $0.id == summary.id }) {
                chatSessions.insert(summary, at: 0)
            }
            return
        }
        var sessions = workSessionsByProjectPath[cwd] ?? []
        if !sessions.contains(where: { $0.id == summary.id }) {
            sessions.insert(summary, at: 0)
        }
        workSessionsByProjectPath[cwd] = sessions
    }

    private func publishReducerState() {
        records = reducer.records
    }

    private func touchSession(_ sessionId: String) {
        sessionRecency.removeAll { $0 == sessionId }
        sessionRecency.append(sessionId)
    }

    private func trimSessionCache(protecting additionalSessionIDs: Set<String> = []) async {
        let selectedSessionIDs = Set(
            [selectedChatSessionId].compactMap { $0 }
                + Array(selectedWorkSessionIdByProjectPath.values)
        )
        let runningSessionIDs = Set(
            reducer.records.values.compactMap { record in
                record.runState == .idle || record.runState == .failed ? nil : record.id
            }
        )
        let candidates = SessionCachePolicy.evictionCandidates(
            recency: sessionRecency.filter { reducer.records[$0] != nil },
            protectedSessionIDs: selectedSessionIDs.union(additionalSessionIDs),
            runningSessionIDs: runningSessionIDs,
            maximumCount: maximumCachedSessionCount
        )
        guard !candidates.isEmpty else { return }

        var didEvict = false
        for sessionId in candidates {
            do {
                _ = try await service.closeSession(
                    sessionId: sessionId,
                    requestID: UUID().uuidString
                )
                reducer.remove(sessionId: sessionId)
                selectedSessionIds.remove(sessionId)
                sessionRecency.removeAll { $0 == sessionId }
                didEvict = true
            } catch {
                continue
            }
        }
        if didEvict { publishReducerState() }
    }

    private func project(
        snapshot: AgentHostSessionSnapshotResult,
        profile: AgentHostSessionProfile,
        sessionDirectory: String?
    ) async -> SessionRecord {
        await Task.detached(priority: .userInitiated) {
            SessionStoreReducer.project(
                snapshot: snapshot,
                profile: profile,
                sessionDirectory: sessionDirectory
            )
        }.value
    }

    private func updateSummaryTitle(sessionId: String, title: String) {
        chatSessions = chatSessions.map { summary in
            summary.id == sessionId ? summary.withTitle(title) : summary
        }
        for (path, sessions) in workSessionsByProjectPath {
            workSessionsByProjectPath[path] = sessions.map { summary in
                summary.id == sessionId ? summary.withTitle(title) : summary
            }
        }
    }

    private func mergeAvailableModels(_ models: [AgentHostModel]) {
        let normalizedModels = models.map(normalizedModel)
        for model in normalizedModels where !availableModels.contains(where: {
            $0.provider == model.provider && $0.id == model.id
        }) {
            availableModels.append(model)
        }
    }

    private func normalizedACPState(_ state: AgentHostACPSessionState) -> AgentHostACPSessionState {
        var state = state
        state.supportsImages = supportsACPImagePrompts
        return state
    }

    private func normalizedModel(_ model: AgentHostModel) -> AgentHostModel {
        guard supportsACPImagePrompts, !model.supportsImages else { return model }
        return AgentHostModel(
            provider: model.provider,
            id: model.id,
            name: model.name,
            contextWindow: model.contextWindow,
            maxTokens: model.maxTokens,
            reasoning: model.reasoning,
            supportsImages: true,
            supportsFastMode: model.supportsFastMode
        )
    }

    private func supportsPiWorkCapability(_ capability: AgentHostPiWorkCapability) -> Bool {
        piWorkCapabilities.contains(capability)
    }

    private static func isMethodNotFound(_ error: Error) -> Bool {
        guard case .requestFailed(let code, _) = error as? AgentHostClientError else {
            return false
        }
        return code == "-32601" || code == "method_not_found"
    }

    private static func timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension AgentHostSessionSummary {
    func withTitle(_ title: String) -> AgentHostSessionSummary {
        AgentHostSessionSummary(
            id: id,
            path: path,
            cwd: cwd,
            title: title,
            firstMessage: firstMessage,
            messageCount: messageCount,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }
}
