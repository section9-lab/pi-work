import Foundation

enum AgentHostServiceError: Error {
    case executableNotFound
    case missingCapabilities([String])
    case missingPiWorkCapability(AgentHostPiWorkCapability)
    case stopped
}

enum AgentHostServiceLifecycleError: Error, Equatable {
    case connectionLost
}

enum AgentHostServiceLifecycleEvent: Equatable {
    case connected(generation: Int, hello: AgentHostHelloPayload)
    case disconnected(generation: Int, error: AgentHostServiceLifecycleError)
    case restarted(generation: Int, hello: AgentHostHelloPayload)
}

private struct StartedAgentHost {
    let client: AgentHostClient
    let hello: AgentHostHelloPayload
}

protocol AgentHostServicing: Actor {
    func events() -> AsyncStream<AgentHostServerEvent>
    func lifecycleEvents() -> AsyncStream<AgentHostServiceLifecycleEvent>
    func start() async throws -> AgentHostHelloPayload
    func stop() async
    func listSessions(
        cwd: String,
        sessionDirectory: String?,
        requestID: String
    ) async throws -> [AgentHostSessionSummary]
    func listModels(requestID: String) async throws -> [AgentHostModel]
    func gitBranches(
        cwd: String,
        requestID: String
    ) async throws -> AgentHostGitBranchesResult
    func createDraft(
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        requestID: String
    ) async throws -> AgentHostSessionCreateDraftResult
    func openSession(
        sessionId: String,
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        requestID: String
    ) async throws -> AgentHostSessionOpenResult
    func exportHTML(
        sessionId: String,
        path: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        outputPath: String,
        requestID: String
    ) async throws -> AgentHostSessionExportHTMLResult
    func snapshot(
        sessionId: String,
        requestID: String
    ) async throws -> AgentHostSessionSnapshotResult
    func transcriptPage(
        sessionId: String,
        cursor: String,
        limit: Int,
        requestID: String
    ) async throws -> AgentHostSessionTranscriptPageResult
    func toolOutput(
        sessionId: String,
        toolCallId: String,
        requestID: String
    ) async throws -> AgentHostSessionToolOutputResult
    func listSlashCommands(
        sessionId: String,
        requestID: String
    ) async throws -> [AgentHostSlashCommand]
    func renameSession(
        sessionId: String,
        title: String,
        requestID: String
    ) async throws -> AgentHostSessionRenameResult
    func setGitBranch(
        sessionId: String,
        branch: String,
        requestID: String
    ) async throws -> AgentHostSessionSetGitBranchResult
    func setModel(
        sessionId: String,
        provider: String,
        modelId: String,
        requestID: String
    ) async throws -> AgentHostSessionSetModelResult
    func setModelOption(
        sessionId: String,
        option: AgentHostModelOption,
        enabled: Bool,
        requestID: String
    ) async throws -> AgentHostSessionSetModelOptionResult
    func setThinkingLevel(
        sessionId: String,
        thinkingLevel: AgentHostThinkingLevel,
        requestID: String
    ) async throws -> AgentHostSessionSetThinkingLevelResult
    func setConfigOption(
        sessionId: String,
        configId: String,
        value: AgentHostACPSetConfigOptionResult.ConfigOption.Value,
        requestID: String
    ) async throws -> AgentHostACPSetConfigOptionResult
    func setSessionMode(
        sessionId: String,
        modeId: String,
        requestID: String
    ) async throws
    func setAccessMode(
        sessionId: String,
        accessMode: AgentHostAccessMode,
        requestID: String
    ) async throws -> AgentHostSessionSetAccessModeResult
    func resolveApproval(
        sessionId: String,
        requestId: String,
        decision: AgentHostApprovalDecision,
        requestID: String
    ) async throws -> AgentHostSessionResolveApprovalResult
    func resolveElicitation(
        sessionId: String?,
        requestId: String,
        response: AgentHostACPElicitationResponse,
        requestID: String
    ) async throws
    func prompt(
        sessionId: String,
        turnId: String,
        text: String,
        images: [AgentHostPromptImage],
        requestID: String
    ) async throws -> AgentHostSessionPromptResult
    func abort(
        sessionId: String,
        requestID: String
    ) async throws -> AgentHostSessionAbortResult
    func closeSession(
        sessionId: String,
        requestID: String
    ) async throws -> AgentHostSessionCloseResult
    func deleteSession(
        sessionId: String,
        cwd: String,
        sessionDirectory: String?,
        requestID: String
    ) async throws -> AgentHostSessionDeleteResult
}

extension AgentHostServicing {
    func setConfigOption(
        sessionId: String,
        configId: String,
        value: AgentHostACPSetConfigOptionResult.ConfigOption.Value,
        requestID: String
    ) async throws -> AgentHostACPSetConfigOptionResult {
        throw AgentHostClientError.requestFailed(
            code: "unsupported_config_option",
            message: "The agent service does not support arbitrary config options"
        )
    }

    func setSessionMode(
        sessionId: String,
        modeId: String,
        requestID: String
    ) async throws {
        throw AgentHostClientError.requestFailed(
            code: "unsupported_session_mode",
            message: "The agent service does not support arbitrary session modes"
        )
    }

    func resolveElicitation(
        sessionId: String?,
        requestId: String,
        response: AgentHostACPElicitationResponse,
        requestID: String
    ) async throws {
        throw AgentHostClientError.requestFailed(
            code: "unsupported_elicitation",
            message: "The agent service does not support ACP elicitation"
        )
    }
}

protocol ProviderAuthServicing: Actor {
    func events() -> AsyncStream<AgentHostServerEvent>
    func lifecycleEvents() -> AsyncStream<AgentHostServiceLifecycleEvent>
    func agentAuthenticationMethods() async throws -> [AgentHostACPAuthMethod]
    func authenticateAgent(methodId: String, requestID: String) async throws
    func logoutAgent(requestID: String) async throws
    func listProviders(requestID: String) async throws -> [AgentHostProvider]
    func startAuthentication(
        flowId: String,
        providerId: String,
        method: AgentHostAuthMethod,
        requestID: String
    ) async throws -> AgentHostAuthStartResult
    func respondToAuthentication(
        flowId: String,
        promptId: String,
        value: String,
        requestID: String
    ) async throws -> AgentHostAuthAcceptedResult
    func cancelAuthentication(
        flowId: String,
        requestID: String
    ) async throws -> AgentHostAuthCancelResult
    func logoutProvider(
        providerId: String,
        requestID: String
    ) async throws -> AgentHostAuthLogoutResult
}

extension ProviderAuthServicing {
    func agentAuthenticationMethods() async throws -> [AgentHostACPAuthMethod] { [] }

    func authenticateAgent(methodId: String, requestID: String) async throws {
        throw AgentHostClientError.requestFailed(
            code: "unsupported_agent_authentication",
            message: "The agent service does not support ACP authentication"
        )
    }

    func logoutAgent(requestID: String) async throws {
        throw AgentHostClientError.requestFailed(
            code: "unsupported_agent_logout",
            message: "The agent service does not support ACP logout"
        )
    }
}

protocol AgentSettingsServicing: Actor {
    func listModels(requestID: String) async throws -> [AgentHostModel]
    func getAgentSettings(requestID: String) async throws -> AgentHostSettings
    func updateAgentSettings(
        _ patch: AgentHostSettingsPatch,
        requestID: String
    ) async throws -> AgentHostSettings
}

protocol InstalledExtensionsServicing: Actor {
    func listExtensionSettings(
        requestID: String
    ) async throws -> [AgentHostExtensionSettings]
    func updateExtensionSettings(
        source: String,
        scope: AgentHostExtensionPackageScope,
        changes: [AgentHostExtensionSettingChange],
        requestID: String
    ) async throws -> AgentHostExtensionSettings
    func listInstalledExtensions(
        requestID: String
    ) async throws -> [AgentHostInstalledExtensionPackage]
    func installExtension(
        source: String,
        requestID: String
    ) async throws -> [AgentHostInstalledExtensionPackage]
    func setInstalledExtensionEnabled(
        source: String,
        scope: AgentHostExtensionPackageScope,
        enabled: Bool,
        requestID: String
    ) async throws -> [AgentHostInstalledExtensionPackage]
    func updateInstalledExtension(
        source: String,
        scope: AgentHostExtensionPackageScope,
        requestID: String
    ) async throws -> [AgentHostInstalledExtensionPackage]
    func removeInstalledExtension(
        source: String,
        scope: AgentHostExtensionPackageScope,
        requestID: String
    ) async throws -> [AgentHostInstalledExtensionPackage]
}

extension AgentHostACPSessionState {
    var thinkingLevel: AgentHostThinkingLevel? {
        guard case .string(let value)? = thinkingConfigOption?.currentValue else {
            return nil
        }
        return AgentHostThinkingLevel(rawValue: value)
    }

    var availableThinkingLevels: [AgentHostThinkingLevel] {
        thinkingConfigOption?.options?.compactMap {
            AgentHostThinkingLevel(rawValue: $0.value)
        } ?? []
    }

    var modelOptions: AgentHostModelOptions {
        AgentHostModelOptions(
            fastMode: modelOptionState(id: "fast_mode"),
            oneMillionContext: modelOptionState(id: "one_million_context")
        )
    }

    var model: AgentHostModel? {
        guard
            let option = modelConfigOption,
            case .string(let value) = option.currentValue
        else { return nil }
        let identity = modelIdentity(value)
        let name = option.options?.first(where: { $0.value == value })?.name ?? identity.modelId
        return AgentHostModel(
            provider: identity.provider,
            id: identity.modelId,
            name: name,
            contextWindow: 0,
            maxTokens: 0,
            reasoning: !availableThinkingLevels.isEmpty,
            supportsImages: supportsImages,
            supportsFastMode: modelOptions.fastMode.supported
        )
    }

    var availableModels: [AgentHostModel] {
        guard let option = modelConfigOption else { return [] }
        return option.options?.map { choice in
            let identity = modelIdentity(choice.value)
            return AgentHostModel(
                provider: identity.provider,
                id: identity.modelId,
                name: choice.name,
                contextWindow: 0,
                maxTokens: 0,
                reasoning: !availableThinkingLevels.isEmpty,
                supportsImages: supportsImages,
                supportsFastMode: modelOptions.fastMode.supported
            )
        } ?? []
    }

    var accessMode: AgentHostAccessMode? {
        modes.flatMap { AgentHostAccessMode(rawValue: $0.currentModeId) }
    }

    var modelConfigOption: AgentHostACPSetConfigOptionResult.ConfigOption? {
        configOptions.first { $0.category == "model" }
            ?? option(id: "model")
    }

    var thinkingConfigOption: AgentHostACPSetConfigOptionResult.ConfigOption? {
        configOptions.first { $0.category == "thought_level" }
            ?? option(id: "thought_level")
    }

    func option(id: String) -> AgentHostACPSetConfigOptionResult.ConfigOption? {
        configOptions.first { $0.id == id }
    }

    func modelOptionState(id: String) -> AgentHostModelOptionState {
        guard let option = option(id: id),
              case .boolean(let enabled) = option.currentValue else {
            return AgentHostModelOptionState(supported: false, enabled: false)
        }
        return AgentHostModelOptionState(supported: true, enabled: enabled)
    }

    private func modelIdentity(_ value: String) -> (provider: String, modelId: String) {
        guard let separator = value.firstIndex(of: "/"),
              separator != value.startIndex,
              value.index(after: separator) != value.endIndex else {
            return ("", value)
        }
        return (
            String(value[..<separator]),
            String(value[value.index(after: separator)...])
        )
    }
}

actor AgentHostService: AgentHostServicing,
    ProviderAuthServicing,
    AgentSettingsServicing,
    InstalledExtensionsServicing {
    static let coreCapabilities: Set<String> = []

    static func bundled() throws -> AgentHostService {
        guard
            let executableURL = AgentHostExecutable.bundledURL(),
            let bunExecutableURL = AgentHostExecutable.bundledBunURL()
        else {
            throw AgentHostServiceError.executableNotFound
        }
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let authenticationFile = AgentHostExecutable.authenticationFileURL(
            applicationSupportDirectory: applicationSupport
        )
        let agentDirectory = AgentHostExecutable.agentDirectoryURL(
            applicationSupportDirectory: applicationSupport
        )
        return AgentHostService(
            executableURL: executableURL,
            environment: [
                "PI_WORK_AUTH_PATH": authenticationFile.path,
                "PI_WORK_AGENT_DIR": agentDirectory.path,
                "PI_CODING_AGENT_DIR": agentDirectory.path,
                "PI_WORK_BUN_PATH": bunExecutableURL.path
            ],
            handshakeTimeout: 15
        )
    }

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let requiredCapabilities: Set<String>
    private let handshakeTimeout: TimeInterval

    private var client: AgentHostClient?
    private var hello: AgentHostHelloPayload?
    private var eventContinuations: [
        UUID: AsyncStream<AgentHostServerEvent>.Continuation
    ] = [:]
    private var lifecycleContinuations: [
        UUID: AsyncStream<AgentHostServiceLifecycleEvent>.Continuation
    ] = [:]
    private var eventForwardingTask: Task<Void, Never>?
    private var clientGeneration = 0
    private var automaticRecoveryAttempted = false
    private var isStopping = false
    private var startupTask: Task<StartedAgentHost, Error>?
    private var permissionOptions: [
        String: (sessionId: String, optionIDs: [AgentHostApprovalDecision: String])
    ] = [:]
    private var activeTurnIDs: [String: String] = [:]
    private var eventSequences: [String: Int] = [:]
    private var acpSessionStates: [String: AgentHostACPSessionState] = [:]

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        requiredCapabilities: Set<String> = AgentHostService.coreCapabilities,
        handshakeTimeout: TimeInterval = 5
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.requiredCapabilities = requiredCapabilities
        self.handshakeTimeout = handshakeTimeout
    }

    func events() -> AsyncStream<AgentHostServerEvent> {
        let id = UUID()
        var continuation: AsyncStream<AgentHostServerEvent>.Continuation?
        let stream = AsyncStream<AgentHostServerEvent> { streamContinuation in
            continuation = streamContinuation
            streamContinuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventSubscriber(id) }
            }
        }
        eventContinuations[id] = continuation
        return stream
    }

    func lifecycleEvents() -> AsyncStream<AgentHostServiceLifecycleEvent> {
        let id = UUID()
        var continuation: AsyncStream<AgentHostServiceLifecycleEvent>.Continuation?
        let stream = AsyncStream<AgentHostServiceLifecycleEvent> { streamContinuation in
            continuation = streamContinuation
            streamContinuation.onTermination = { [weak self] _ in
                Task { await self?.removeLifecycleSubscriber(id) }
            }
        }
        lifecycleContinuations[id] = continuation
        if let hello, clientGeneration > 0 {
            let event: AgentHostServiceLifecycleEvent = clientGeneration == 1
                ? .connected(generation: clientGeneration, hello: hello)
                : .restarted(generation: clientGeneration, hello: hello)
            continuation?.yield(event)
        }
        return stream
    }

    func start() async throws -> AgentHostHelloPayload {
        guard !isStopping else {
            throw AgentHostServiceError.stopped
        }
        if let hello {
            return hello
        }

        let task: Task<StartedAgentHost, Error>
        if let startupTask {
            task = startupTask
        } else {
            let executableURL = self.executableURL
            let arguments = self.arguments
            let environment = self.environment
            let requiredCapabilities = self.requiredCapabilities
            let handshakeTimeout = self.handshakeTimeout
            let newTask = Task {
                let candidate = AgentHostClient(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    handshakeTimeout: handshakeTimeout
                )
                return try await withTaskCancellationHandler(operation: {
                    let payload = try await candidate.start()
                    try Task.checkCancellation()
                    let missing = requiredCapabilities.subtracting(payload.capabilities).sorted()
                    guard missing.isEmpty else {
                        await candidate.stop()
                        throw AgentHostServiceError.missingCapabilities(missing)
                    }
                    return StartedAgentHost(client: candidate, hello: payload)
                }, onCancel: {
                    Task { await candidate.stop() }
                })
            }
            startupTask = newTask
            task = newTask
        }

        do {
            let started = try await task.value
            guard !isStopping else {
                await started.client.stop()
                startupTask = nil
                throw AgentHostServiceError.stopped
            }
            if client == nil {
                await install(started)
            }
            startupTask = nil
            return hello ?? started.hello
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func install(_ started: StartedAgentHost) async {
        client = started.client
        hello = started.hello
        clientGeneration += 1
        let generation = clientGeneration
        let lifecycleEvent: AgentHostServiceLifecycleEvent = generation == 1
            ? .connected(generation: generation, hello: started.hello)
            : .restarted(generation: generation, hello: started.hello)
        for continuation in lifecycleContinuations.values {
            continuation.yield(lifecycleEvent)
        }
        let clientEvents = await started.client.events()
        eventForwardingTask = Task { [weak self] in
            for await event in clientEvents {
                await self?.forward(event)
            }
            await self?.clientEventStreamFinished(generation: generation)
        }
    }

    func request<Parameters: Encodable, Result: Decodable>(
        id: String = UUID().uuidString,
        method: String,
        params: Parameters,
        timeout: TimeInterval = 30,
        as responseType: Result.Type
    ) async throws -> Result {
        let hello = try await start()
        if let capability = AgentHostPiWorkCapability(rawValue: method),
           !hello.supportsPiWorkCapability(capability) {
            throw AgentHostServiceError.missingPiWorkCapability(capability)
        }
        guard let client else {
            throw AgentHostClientError.notRunning
        }
        return try await client.request(
            id: id,
            method: method,
            params: params,
            timeout: timeout,
            as: responseType
        )
    }

    func listSessions(
        cwd: String,
        sessionDirectory: String?,
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostSessionSummary] {
        let result: AgentHostACPSessionListResult = try await request(
            id: requestID,
            method: "sessions.list",
            params: AgentHostSessionListParameters(
                cwd: cwd,
                sessionDirectory: sessionDirectory
            ),
            as: AgentHostACPSessionListResult.self
        )
        return result.sessions.map(\.summary)
    }

    func listModels(
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostModel] {
        let result: AgentHostModelListResult = try await request(
            id: requestID,
            method: "models.list",
            params: AgentHostEmptyParameters(),
            as: AgentHostModelListResult.self
        )
        return result.models
    }

    func gitBranches(
        cwd: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostGitBranchesResult {
        try await request(
            id: requestID,
            method: "git.branches",
            params: AgentHostGitBranchesParameters(cwd: cwd),
            as: AgentHostGitBranchesResult.self
        )
    }

    func getAgentSettings(
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSettings {
        try await request(
            id: requestID,
            method: "settings.get",
            params: AgentHostEmptyParameters(),
            as: AgentHostSettings.self
        )
    }

    func updateAgentSettings(
        _ patch: AgentHostSettingsPatch,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSettings {
        try await request(
            id: requestID,
            method: "settings.update",
            params: AgentHostSettingsUpdateParameters(patch: patch),
            as: AgentHostSettings.self
        )
    }

    func listInstalledExtensions(
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostInstalledExtensionPackage] {
        let result: AgentHostInstalledExtensionsResult = try await request(
            id: requestID,
            method: "extensions.listInstalled",
            params: AgentHostEmptyParameters(),
            as: AgentHostInstalledExtensionsResult.self
        )
        return result.packages
    }

    func listExtensionSettings(
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostExtensionSettings] {
        let result: AgentHostExtensionSettingsResult = try await request(
            id: requestID,
            method: "extensions.settings.list",
            params: AgentHostEmptyParameters(),
            as: AgentHostExtensionSettingsResult.self
        )
        return result.extensions
    }

    func updateExtensionSettings(
        source: String,
        scope: AgentHostExtensionPackageScope,
        changes: [AgentHostExtensionSettingChange],
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostExtensionSettings {
        try await request(
            id: requestID,
            method: "extensions.settings.update",
            params: AgentHostExtensionSettingsUpdateParameters(
                source: source,
                scope: scope,
                changes: changes
            ),
            as: AgentHostExtensionSettings.self
        )
    }

    func installExtension(
        source: String,
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostInstalledExtensionPackage] {
        let result: AgentHostInstalledExtensionsResult = try await request(
            id: requestID,
            method: "extensions.install",
            params: AgentHostExtensionInstallParameters(source: source),
            timeout: 120,
            as: AgentHostInstalledExtensionsResult.self
        )
        return result.packages
    }

    func setInstalledExtensionEnabled(
        source: String,
        scope: AgentHostExtensionPackageScope,
        enabled: Bool,
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostInstalledExtensionPackage] {
        let result: AgentHostInstalledExtensionsResult = try await request(
            id: requestID,
            method: "extensions.setEnabled",
            params: AgentHostExtensionEnabledParameters(
                source: source,
                scope: scope,
                enabled: enabled
            ),
            as: AgentHostInstalledExtensionsResult.self
        )
        return result.packages
    }

    func updateInstalledExtension(
        source: String,
        scope: AgentHostExtensionPackageScope,
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostInstalledExtensionPackage] {
        let result: AgentHostInstalledExtensionsResult = try await request(
            id: requestID,
            method: "extensions.update",
            params: AgentHostExtensionPackageParameters(source: source, scope: scope),
            timeout: 120,
            as: AgentHostInstalledExtensionsResult.self
        )
        return result.packages
    }

    func removeInstalledExtension(
        source: String,
        scope: AgentHostExtensionPackageScope,
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostInstalledExtensionPackage] {
        let result: AgentHostInstalledExtensionsResult = try await request(
            id: requestID,
            method: "extensions.remove",
            params: AgentHostExtensionPackageParameters(source: source, scope: scope),
            timeout: 120,
            as: AgentHostInstalledExtensionsResult.self
        )
        return result.packages
    }

    func listProviders(
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostProvider] {
        let result: AgentHostProviderListResult = try await request(
            id: requestID,
            method: "providers.list",
            params: AgentHostEmptyParameters(),
            as: AgentHostProviderListResult.self
        )
        return result.providers
    }

    func agentAuthenticationMethods() async throws -> [AgentHostACPAuthMethod] {
        try await start().authMethods.filter { $0.type != "terminal" }
    }

    func authenticateAgent(
        methodId: String,
        requestID: String = UUID().uuidString
    ) async throws {
        let _: AgentHostACPEmptyResult = try await request(
            id: requestID,
            method: "authenticate",
            params: AgentHostACPAuthenticateParameters(methodId: methodId),
            as: AgentHostACPEmptyResult.self
        )
    }

    func logoutAgent(
        requestID: String = UUID().uuidString
    ) async throws {
        let _: AgentHostACPEmptyResult = try await request(
            id: requestID,
            method: "logout",
            params: AgentHostEmptyParameters(),
            as: AgentHostACPEmptyResult.self
        )
    }

    func startAuthentication(
        flowId: String,
        providerId: String,
        method: AgentHostAuthMethod,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostAuthStartResult {
        try await request(
            id: requestID,
            method: "auth.start",
            params: AgentHostAuthStartParameters(
                flowId: flowId,
                providerId: providerId,
                method: method
            ),
            as: AgentHostAuthStartResult.self
        )
    }

    func respondToAuthentication(
        flowId: String,
        promptId: String,
        value: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostAuthAcceptedResult {
        try await request(
            id: requestID,
            method: "auth.respond",
            params: AgentHostAuthRespondParameters(
                flowId: flowId,
                promptId: promptId,
                value: value
            ),
            as: AgentHostAuthAcceptedResult.self
        )
    }

    func cancelAuthentication(
        flowId: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostAuthCancelResult {
        try await request(
            id: requestID,
            method: "auth.cancel",
            params: AgentHostAuthCancelParameters(flowId: flowId),
            as: AgentHostAuthCancelResult.self
        )
    }

    func logoutProvider(
        providerId: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostAuthLogoutResult {
        try await request(
            id: requestID,
            method: "auth.logout",
            params: AgentHostAuthLogoutParameters(providerId: providerId),
            as: AgentHostAuthLogoutResult.self
        )
    }

    func createDraft(
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionCreateDraftResult {
        let result: AgentHostACPSessionNewResult = try await request(
            id: requestID,
            method: "session.createDraft",
            params: AgentHostSessionCreateDraftParameters(
                cwd: cwd,
                sessionDirectory: sessionDirectory,
                profile: profile
            ),
            as: AgentHostACPSessionNewResult.self
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let summary = AgentHostSessionSummary(
            id: result.sessionId,
            path: result.sessionId,
            cwd: cwd,
            title: "New Session",
            firstMessage: "",
            messageCount: 0,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
        acpSessionStates[result.sessionId] = result.acpState
        return AgentHostSessionCreateDraftResult(
            session: summary,
            acpState: result.acpState
        )
    }

    func openSession(
        sessionId: String,
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionOpenResult {
        _ = try await start()
        let method = hello?.acpCapabilities.loadSession == true
            ? "session/load"
            : "session/resume"
        let result: AgentHostACPSessionResumeResult = try await request(
            id: requestID,
            method: method,
            params: AgentHostACPSessionOpenParameters(
                sessionId: sessionId,
                cwd: cwd,
                sessionDirectory: sessionDirectory,
                profile: profile
            ),
            as: AgentHostACPSessionResumeResult.self
        )
        acpSessionStates[sessionId] = result.acpState
        return AgentHostSessionOpenResult(
            sessionId: sessionId,
            path: sessionId,
            cwd: cwd,
            acpState: result.acpState
        )
    }

    func exportHTML(
        sessionId: String,
        path: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile,
        outputPath: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionExportHTMLResult {
        try await request(
            id: requestID,
            method: "session.exportHtml",
            params: AgentHostSessionExportHTMLParameters(
                sessionId: sessionId,
                path: path,
                sessionDirectory: sessionDirectory,
                profile: profile,
                outputPath: outputPath
            ),
            as: AgentHostSessionExportHTMLResult.self
        )
    }

    func snapshot(
        sessionId: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionSnapshotResult {
        try await request(
            id: requestID,
            method: "session.snapshot",
            params: AgentHostSessionIdentifierParameters(sessionId: sessionId),
            as: AgentHostSessionSnapshotResult.self
        )
    }

    func transcriptPage(
        sessionId: String,
        cursor: String,
        limit: Int,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionTranscriptPageResult {
        try await request(
            id: requestID,
            method: "session.transcriptPage",
            params: AgentHostSessionTranscriptPageParameters(
                sessionId: sessionId,
                cursor: cursor,
                limit: limit
            ),
            as: AgentHostSessionTranscriptPageResult.self
        )
    }

    func toolOutput(
        sessionId: String,
        toolCallId: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionToolOutputResult {
        try await request(
            id: requestID,
            method: "session.toolOutput",
            params: AgentHostSessionToolOutputParameters(
                sessionId: sessionId,
                toolCallId: toolCallId
            ),
            as: AgentHostSessionToolOutputResult.self
        )
    }

    func listSlashCommands(
        sessionId: String,
        requestID: String = UUID().uuidString
    ) async throws -> [AgentHostSlashCommand] {
        let result: AgentHostSlashCommandsResult = try await request(
            id: requestID,
            method: "session.commands",
            params: AgentHostSessionIdentifierParameters(sessionId: sessionId),
            as: AgentHostSlashCommandsResult.self
        )
        return result.commands
    }

    func renameSession(
        sessionId: String,
        title: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionRenameResult {
        try await request(
            id: requestID,
            method: "session.rename",
            params: AgentHostSessionRenameParameters(sessionId: sessionId, title: title),
            as: AgentHostSessionRenameResult.self
        )
    }

    func setGitBranch(
        sessionId: String,
        branch: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionSetGitBranchResult {
        try await request(
            id: requestID,
            method: "session.setGitBranch",
            params: AgentHostSessionSetGitBranchParameters(
                sessionId: sessionId,
                branch: branch
            ),
            as: AgentHostSessionSetGitBranchResult.self
        )
    }

    func setModel(
        sessionId: String,
        provider: String,
        modelId: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionSetModelResult {
        let state = acpSessionStates[sessionId] ?? .empty
        let configOption = state.modelConfigOption
        let qualifiedModelId = provider.isEmpty ? modelId : "\(provider)/\(modelId)"
        let value = configOption?.options?.first(where: {
            $0.value == qualifiedModelId || $0.value == modelId
        })?.value ?? qualifiedModelId
        let result: AgentHostACPSetConfigOptionResult = try await request(
            id: requestID,
            method: "session/set_config_option",
            params: AgentHostACPSetStringConfigOptionParameters(
                sessionId: sessionId,
                configId: configOption?.id ?? "model",
                value: value
            ),
            as: AgentHostACPSetConfigOptionResult.self
        )
        acpSessionStates[sessionId] = result.acpState
        guard let model = result.acpState.model else {
            throw AgentHostClientError.requestFailed(
                code: "missing_session_model",
                message: "The agent did not report the selected model"
            )
        }
        return AgentHostSessionSetModelResult(
            sessionId: sessionId,
            model: model,
            contextUsage: nil,
            thinkingLevel: result.acpState.thinkingLevel ?? .off,
            availableThinkingLevels: result.acpState.availableThinkingLevels,
            modelOptions: result.acpState.modelOptions
        )
    }

    func setModelOption(
        sessionId: String,
        option: AgentHostModelOption,
        enabled: Bool,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionSetModelOptionResult {
        let state = acpSessionStates[sessionId] ?? .empty
        let fallbackConfigId = option == .oneMillionContext
            ? "one_million_context"
            : "fast_mode"
        let result: AgentHostACPSetConfigOptionResult = try await request(
            id: requestID,
            method: "session/set_config_option",
            params: AgentHostACPSetBooleanConfigOptionParameters(
                sessionId: sessionId,
                configId: state.option(id: fallbackConfigId)?.id ?? fallbackConfigId,
                value: enabled
            ),
            as: AgentHostACPSetConfigOptionResult.self
        )
        acpSessionStates[sessionId] = result.acpState
        guard let model = result.acpState.model else {
            throw AgentHostClientError.requestFailed(
                code: "missing_session_model",
                message: "The agent did not report the selected model"
            )
        }
        return AgentHostSessionSetModelOptionResult(
            sessionId: sessionId,
            model: model,
            contextUsage: nil,
            modelOptions: result.acpState.modelOptions
        )
    }

    func setThinkingLevel(
        sessionId: String,
        thinkingLevel: AgentHostThinkingLevel,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionSetThinkingLevelResult {
        let configId = acpSessionStates[sessionId]?.thinkingConfigOption?.id
            ?? "thought_level"
        let result: AgentHostACPSetConfigOptionResult = try await request(
            id: requestID,
            method: "session/set_config_option",
            params: AgentHostACPSetStringConfigOptionParameters(
                sessionId: sessionId,
                configId: configId,
                value: thinkingLevel.rawValue
            ),
            as: AgentHostACPSetConfigOptionResult.self
        )
        acpSessionStates[sessionId] = result.acpState
        return AgentHostSessionSetThinkingLevelResult(
            sessionId: sessionId,
            thinkingLevel: result.acpState.thinkingLevel ?? thinkingLevel,
            availableThinkingLevels: result.acpState.availableThinkingLevels
        )
    }

    func setConfigOption(
        sessionId: String,
        configId: String,
        value: AgentHostACPSetConfigOptionResult.ConfigOption.Value,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostACPSetConfigOptionResult {
        let result: AgentHostACPSetConfigOptionResult
        switch value {
        case .string(let value):
            result = try await request(
                id: requestID,
                method: "session/set_config_option",
                params: AgentHostACPSetStringConfigOptionParameters(
                    sessionId: sessionId,
                    configId: configId,
                    value: value
                ),
                as: AgentHostACPSetConfigOptionResult.self
            )
        case .boolean(let value):
            result = try await request(
                id: requestID,
                method: "session/set_config_option",
                params: AgentHostACPSetBooleanConfigOptionParameters(
                    sessionId: sessionId,
                    configId: configId,
                    value: value
                ),
                as: AgentHostACPSetConfigOptionResult.self
            )
        }
        acpSessionStates[sessionId] = result.acpState
        return result
    }

    func setSessionMode(
        sessionId: String,
        modeId: String,
        requestID: String = UUID().uuidString
    ) async throws {
        let _: AgentHostACPEmptyResult = try await request(
            id: requestID,
            method: "session/set_mode",
            params: AgentHostACPSetModeParameters(sessionId: sessionId, modeId: modeId),
            as: AgentHostACPEmptyResult.self
        )
        if var state = acpSessionStates[sessionId], var modes = state.modes {
            modes.currentModeId = modeId
            state.modes = modes
            acpSessionStates[sessionId] = state
        }
    }

    func setAccessMode(
        sessionId: String,
        accessMode: AgentHostAccessMode,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionSetAccessModeResult {
        try await setSessionMode(
            sessionId: sessionId,
            modeId: accessMode.rawValue,
            requestID: requestID
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
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionResolveApprovalResult {
        _ = requestID
        _ = try await start()
        guard let client else { throw AgentHostClientError.notRunning }
        let options = permissionOptions[requestId]
        let optionId = options?.optionIDs[decision]
        guard let optionId else {
            throw AgentHostClientError.requestFailed(
                code: "permission_option_not_found",
                message: "The agent did not provide a matching permission option"
            )
        }
        try await client.respondToPermission(requestId: requestId, optionId: optionId)
        permissionOptions.removeValue(forKey: requestId)
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
        requestID: String = UUID().uuidString
    ) async throws {
        _ = sessionId
        _ = requestID
        _ = try await start()
        guard let client else { throw AgentHostClientError.notRunning }
        try await client.respondToElicitation(requestId: requestId, response: response)
    }

    func prompt(
        sessionId: String,
        turnId: String,
        text: String,
        images: [AgentHostPromptImage] = [],
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionPromptResult {
        activeTurnIDs[sessionId] = turnId
        do {
            let _: AgentHostACPPromptResult = try await request(
                id: requestID,
                method: "session.prompt",
                params: AgentHostSessionPromptParameters(
                    sessionId: sessionId,
                    turnId: turnId,
                    text: text,
                    images: images
                ),
                as: AgentHostACPPromptResult.self
            )
        } catch {
            activeTurnIDs.removeValue(forKey: sessionId)
            throw error
        }
        activeTurnIDs.removeValue(forKey: sessionId)
        return AgentHostSessionPromptResult(
            accepted: true,
            sessionId: sessionId,
            turnId: turnId
        )
    }

    func abort(
        sessionId: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionAbortResult {
        _ = requestID
        _ = try await start()
        guard let client else { throw AgentHostClientError.notRunning }
        let pendingRequestIDs = permissionOptions.compactMap { requestId, options in
            options.sessionId == sessionId ? requestId : nil
        }
        for requestId in pendingRequestIDs {
            try await client.cancelPermission(requestId: requestId)
            permissionOptions.removeValue(forKey: requestId)
        }
        try await client.notify(
            method: "session.abort",
            params: AgentHostSessionIdentifierParameters(sessionId: sessionId)
        )
        return AgentHostSessionAbortResult(aborted: true, sessionId: sessionId)
    }

    func closeSession(
        sessionId: String,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionCloseResult {
        let _: AgentHostACPEmptyResult = try await request(
            id: requestID,
            method: "session.close",
            params: AgentHostSessionIdentifierParameters(sessionId: sessionId),
            as: AgentHostACPEmptyResult.self
        )
        return AgentHostSessionCloseResult(
            closed: true,
            sessionId: sessionId
        )
    }

    func deleteSession(
        sessionId: String,
        cwd: String,
        sessionDirectory: String?,
        requestID: String = UUID().uuidString
    ) async throws -> AgentHostSessionDeleteResult {
        let _: AgentHostACPEmptyResult = try await request(
            id: requestID,
            method: "session.delete",
            params: AgentHostSessionDeleteParameters(
                sessionId: sessionId,
                cwd: cwd,
                sessionDirectory: sessionDirectory
            ),
            as: AgentHostACPEmptyResult.self
        )
        return AgentHostSessionDeleteResult(
            deleted: true,
            sessionId: sessionId
        )
    }

    func stop() async {
        isStopping = true
        startupTask?.cancel()
        startupTask = nil
        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        if let client {
            await client.stop()
        }
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
        for continuation in lifecycleContinuations.values {
            continuation.finish()
        }
        lifecycleContinuations.removeAll()
        client = nil
        hello = nil
        permissionOptions.removeAll()
        activeTurnIDs.removeAll()
        eventSequences.removeAll()
    }

    private func forward(_ event: AgentHostServerEvent) {
        let event = correlate(event)
        if case .sessionConfigOptionsChanged(let payload) = event {
            var state = acpSessionStates[payload.sessionId] ?? .empty
            state.configOptions = payload.configOptions
            acpSessionStates[payload.sessionId] = state
        } else if case .sessionModeChanged(let payload) = event {
            var state = acpSessionStates[payload.sessionId] ?? .empty
            if var modes = state.modes {
                modes.currentModeId = payload.currentModeId
                state.modes = modes
            } else {
                state.modes = AgentHostACPSessionModeState(
                    currentModeId: payload.currentModeId,
                    availableModes: []
                )
            }
            acpSessionStates[payload.sessionId] = state
        }
        if case .sessionApprovalRequested(let payload) = event {
            var optionIDs: [AgentHostApprovalDecision: String] = [:]
            for option in payload.options {
                optionIDs[option.kind.decision] = option.optionId
            }
            if optionIDs[.allowOnce] == nil, let allow = payload.allowOptionId {
                optionIDs[.allowOnce] = allow
            }
            if optionIDs[.deny] == nil, let reject = payload.rejectOptionId {
                optionIDs[.deny] = reject
            }
            permissionOptions[payload.requestId] = (
                sessionId: payload.sessionId,
                optionIDs: optionIDs
            )
        }
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func correlate(_ event: AgentHostServerEvent) -> AgentHostServerEvent {
        func values(sessionId: String, sequence: Int, turnId: String) -> (Int, String) {
            let correlatedSequence: Int
            if sequence > 0 {
                correlatedSequence = sequence
            } else {
                correlatedSequence = (eventSequences[sessionId] ?? 0) + 1
            }
            eventSequences[sessionId] = max(eventSequences[sessionId] ?? 0, correlatedSequence)
            return (correlatedSequence, turnId.isEmpty ? activeTurnIDs[sessionId] ?? "" : turnId)
        }

        switch event {
        case .sessionStateChanged(let payload):
            let value = values(
                sessionId: payload.sessionId,
                sequence: payload.sequence,
                turnId: payload.turnId
            )
            return .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    turnId: value.1,
                    state: payload.state,
                    contextUsage: payload.contextUsage
                )
            )
        case .sessionMessageDelta(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: payload.turnId)
            return .sessionMessageDelta(
                AgentHostSessionMessageDeltaPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    turnId: value.1,
                    delta: payload.delta
                )
            )
        case .sessionUserContent(let payload):
            let value = values(
                sessionId: payload.sessionId,
                sequence: payload.sequence,
                turnId: payload.messageId
            )
            return .sessionUserContent(
                AgentHostSessionUserContentPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    messageId: value.1.isEmpty ? "acp-message-\(value.0)" : value.1,
                    text: payload.text
                )
            )
        case .sessionAssistantContent(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: payload.turnId)
            return .sessionAssistantContent(
                AgentHostSessionAssistantContentPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    turnId: value.1,
                    generationIndex: payload.generationIndex,
                    phase: payload.phase,
                    contentType: payload.contentType,
                    contentIndex: payload.contentIndex,
                    delta: payload.delta,
                    content: payload.content,
                    toolCall: payload.toolCall
                )
            )
        case .sessionToolStarted(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: payload.turnId)
            return .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    turnId: value.1,
                    toolCallId: payload.toolCallId,
                    toolName: payload.toolName,
                    summary: payload.summary,
                    content: payload.content,
                    rawInput: payload.rawInput
                )
            )
        case .sessionToolUpdated(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: payload.turnId)
            return .sessionToolUpdated(
                AgentHostSessionToolUpdatedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    turnId: value.1,
                    toolCallId: payload.toolCallId,
                    toolName: payload.toolName,
                    output: payload.output,
                    content: payload.content,
                    rawOutput: payload.rawOutput
                )
            )
        case .sessionToolCompleted(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: payload.turnId)
            return .sessionToolCompleted(
                AgentHostSessionToolCompletedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    turnId: value.1,
                    toolCallId: payload.toolCallId,
                    toolName: payload.toolName,
                    output: payload.output,
                    content: payload.content,
                    rawOutput: payload.rawOutput,
                    isError: payload.isError
                )
            )
        case .sessionApprovalRequested(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: payload.turnId)
            return .sessionApprovalRequested(
                AgentHostSessionApprovalRequestedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    turnId: value.1,
                    requestId: payload.requestId,
                    toolCallId: payload.toolCallId,
                    toolName: payload.toolName,
                    summary: payload.summary,
                    allowOptionId: payload.allowOptionId,
                    rejectOptionId: payload.rejectOptionId,
                    options: payload.options
                )
            )
        case .sessionError(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: payload.turnId)
            return .sessionError(
                AgentHostSessionErrorPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    turnId: value.1,
                    code: payload.code,
                    message: payload.message
                )
            )
        case .sessionModeChanged(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: "")
            return .sessionModeChanged(
                AgentHostSessionModeChangedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    currentModeId: payload.currentModeId
                )
            )
        case .sessionConfigOptionsChanged(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: "")
            return .sessionConfigOptionsChanged(
                AgentHostSessionConfigOptionsChangedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    configOptions: payload.configOptions
                )
            )
        case .sessionInfoChanged(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: "")
            return .sessionInfoChanged(
                AgentHostSessionInfoChangedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    title: payload.title,
                    updatedAt: payload.updatedAt
                )
            )
        case .sessionUsageChanged(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: "")
            return .sessionUsageChanged(
                AgentHostSessionUsageChangedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    used: payload.used,
                    size: payload.size,
                    cost: payload.cost
                )
            )
        case .sessionAvailableCommandsChanged(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: "")
            return .sessionAvailableCommandsChanged(
                AgentHostSessionAvailableCommandsChangedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    availableCommands: payload.availableCommands
                )
            )
        case .sessionPlanChanged(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: "")
            return .sessionPlanChanged(
                AgentHostSessionPlanChangedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    entries: payload.entries
                )
            )
        case .sessionExtensionStatusChanged(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: "")
            return .sessionExtensionStatusChanged(
                AgentHostSessionExtensionStatusChangedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    key: payload.key,
                    text: payload.text
                )
            )
        case .sessionExtensionWidgetChanged(let payload):
            let value = values(sessionId: payload.sessionId, sequence: payload.sequence, turnId: "")
            return .sessionExtensionWidgetChanged(
                AgentHostSessionExtensionWidgetChangedPayload(
                    sessionId: payload.sessionId,
                    sequence: value.0,
                    key: payload.key,
                    widget: payload.widget
                )
            )
        default:
            return event
        }
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func removeLifecycleSubscriber(_ id: UUID) {
        lifecycleContinuations[id] = nil
    }

    private func clientEventStreamFinished(generation: Int) async {
        guard generation == clientGeneration else { return }
        client = nil
        hello = nil
        eventForwardingTask = nil
        permissionOptions.removeAll()
        activeTurnIDs.removeAll()
        eventSequences.removeAll()
        acpSessionStates.removeAll()

        guard !isStopping else { return }
        let event = AgentHostServiceLifecycleEvent.disconnected(
            generation: generation,
            error: .connectionLost
        )
        for continuation in lifecycleContinuations.values {
            continuation.yield(event)
        }
        guard !automaticRecoveryAttempted else { return }
        automaticRecoveryAttempted = true
        _ = try? await start()
    }
}
