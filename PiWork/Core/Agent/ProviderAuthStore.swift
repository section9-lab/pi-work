import Foundation
import Combine

enum ProviderAuthenticationGuide {
    static func webURL(from value: String) -> URL? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else { return nil }
        return components.url
    }

    static func credentialHelpURL(for providerID: String) -> URL? {
        let value: String?
        switch providerID.lowercased() {
        case "amazon-bedrock":
            value = "https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html"
        case "ant-ling":
            value = "https://pi.dev/docs/latest/providers#api-keys"
        case "anthropic":
            value = "https://console.anthropic.com/settings/keys"
        case "azure-openai-responses":
            value = "https://portal.azure.com/"
        case "baseten":
            value = "https://docs.baseten.co/organization/api-keys"
        case "cerebras":
            value = "https://cloud.cerebras.ai/platform/"
        case "cloudflare-ai-gateway", "cloudflare-workers-ai":
            value = "https://dash.cloudflare.com/profile/api-tokens"
        case "deepseek":
            value = "https://platform.deepseek.com/api_keys"
        case "fireworks":
            value = "https://app.fireworks.ai/settings/users/api-keys"
        case "github-copilot":
            value = "https://github.com/settings/tokens"
        case "google":
            value = "https://aistudio.google.com/app/apikey"
        case "google-vertex":
            value = "https://console.cloud.google.com/apis/credentials"
        case "groq":
            value = "https://console.groq.com/keys"
        case "huggingface":
            value = "https://huggingface.co/settings/tokens"
        case "kimi-coding", "moonshotai":
            value = "https://platform.moonshot.ai/console/api-keys"
        case "minimax":
            value = "https://platform.minimax.io/docs/guides/quickstart-preparation"
        case "minimax-cn":
            value = "https://platform.minimaxi.com/docs/guides/quickstart-preparation"
        case "mistral":
            value = "https://console.mistral.ai/api-keys"
        case "moonshotai-cn":
            value = "https://platform.moonshot.cn/console/api-keys"
        case "nvidia":
            value = "https://build.nvidia.com/"
        case "openai":
            value = "https://platform.openai.com/api-keys"
        case "opencode", "opencode-go":
            value = "https://opencode.ai/docs/zen"
        case "openrouter":
            value = "https://openrouter.ai/settings/keys"
        case "qwen-token-plan", "qwen-token-plan-individual":
            value = "https://docs.qwencloud.com/developer-guides/administration/api-keys"
        case "qwen-token-plan-cn":
            value = "https://help.aliyun.com/zh/model-studio/get-api-key"
        case "radius":
            value = "https://pi.dev/docs/latest/providers#radius"
        case "together":
            value = "https://docs.together.ai/docs/api-keys-authentication"
        case "vercel-ai-gateway":
            value = "https://vercel.com/docs/ai-gateway/authentication-and-byok"
        case "xai":
            value = "https://console.x.ai/team/default/api-keys"
        case "xiaomi", "xiaomi-token-plan-ams", "xiaomi-token-plan-cn", "xiaomi-token-plan-sgp":
            value = "https://mimo.mi.com/docs/en-US/quick-start/faq/api-integration"
        case "zai":
            value = "https://docs.z.ai/api-reference/introduction"
        case "zai-coding-cn":
            value = "https://open.bigmodel.cn/usercenter/apikeys"
        default:
            value = nil
        }
        return value.flatMap { webURL(from: $0) }
    }
}

enum ProviderAuthenticationPresentation {
    static func promptTitle(
        providerName: String,
        prompt: AgentHostAuthPromptPayload,
        language: AppLanguage = L10n.currentLanguage
    ) -> String {
        switch prompt.type {
        case .secret:
            if prompt.providerId == "amazon-bedrock" {
                return L10n.string("auth.prompt.bedrock.bearer_token", language: language)
            }
            return L10n.format("auth.prompt.api_key", language: language, providerName)
        case .manualCode:
            return L10n.string("auth.prompt.manual_code", language: language)
        case .select:
            switch prompt.providerId {
            case "amazon-bedrock":
                return L10n.string("auth.prompt.bedrock.method", language: language)
            case "google-vertex":
                return L10n.string("auth.prompt.vertex.method", language: language)
            default:
                return L10n.string("auth.prompt.method", language: language)
            }
        case .text:
            return textPromptTitle(prompt, language: language)
        }
    }

    static func optionTitle(
        id: String,
        fallback: String,
        language: AppLanguage = L10n.currentLanguage
    ) -> String {
        let key: String?
        switch id {
        case "browser": key = "auth.option.browser"
        case "manual", "manual_code": key = "auth.option.manual_code"
        case "device-code", "device_code": key = "auth.option.device_code"
        case "bearer-token": key = "auth.option.bearer_token"
        case "aws-profile": key = "auth.option.aws_profile"
        case "credential-chain": key = "auth.option.credential_chain"
        case "oauth": key = "auth.option.oauth"
        case "api-key", "api_key": key = "auth.option.api_key"
        case "adc": key = "auth.option.adc"
        case "service-account": key = "auth.option.service_account"
        default: key = nil
        }
        return key.map { L10n.string($0, language: language) } ?? fallback
    }

    static func inputPlaceholder(
        prompt: AgentHostAuthPromptPayload,
        language: AppLanguage = L10n.currentLanguage
    ) -> String {
        if prompt.type == .manualCode {
            return L10n.string("auth.input.authorization_code", language: language)
        }
        if prompt.providerId == "google-vertex",
           prompt.message.localizedCaseInsensitiveContains("file path") {
            return L10n.string("auth.input.file_path", language: language)
        }
        return prompt.placeholder ?? L10n.string("auth.input_placeholder", language: language)
    }

    static func errorMessage(
        code: String?,
        fallback: String,
        language: AppLanguage = L10n.currentLanguage
    ) -> String {
        let key: String?
        switch code {
        case "login_failed": key = "auth.failed"
        case "auth_network_failed": key = "auth.error.network"
        case "auth_invalid_configuration": key = "auth.error.invalid_configuration"
        case "auth_rejected": key = "auth.error.rejected"
        case "auth_expired": key = "auth.error.expired"
        case "auth_callback_failed": key = "auth.error.callback"
        case "auth_host_restarted": key = "auth.host_restarted"
        default: key = nil
        }
        return key.map { L10n.string($0, language: language) } ?? fallback
    }

    static func informationText(
        _ message: String,
        providerID: String,
        language: AppLanguage = L10n.currentLanguage
    ) -> String {
        if providerID == "google-vertex" {
            return L10n.string("auth.info.vertex", language: language)
        }
        if providerID == "amazon-bedrock" {
            return L10n.string("auth.info.bedrock", language: language)
        }
        if providerID == "radius", message.localizedCaseInsensitiveContains("could not be refreshed") {
            return L10n.string("auth.info.radius_refresh_failed", language: language)
        }
        return message
    }

    static func progressText(
        _ message: String,
        language: AppLanguage = L10n.currentLanguage
    ) -> String {
        if message.localizedCaseInsensitiveContains("callback") {
            return L10n.string("auth.progress.callback", language: language)
        }
        if message.localizedCaseInsensitiveContains("device") {
            return L10n.string("auth.progress.device", language: language)
        }
        return L10n.string("auth.waiting", language: language)
    }

    private static func textPromptTitle(
        _ prompt: AgentHostAuthPromptPayload,
        language: AppLanguage
    ) -> String {
        switch prompt.providerId {
        case "azure-openai-responses":
            return L10n.string("auth.prompt.azure.endpoint", language: language)
        case "amazon-bedrock":
            if prompt.message.localizedCaseInsensitiveContains("profile") {
                return L10n.string("auth.prompt.bedrock.profile", language: language)
            }
            return L10n.string("auth.prompt.bedrock.configured", language: language)
        case "google-vertex":
            if prompt.message.localizedCaseInsensitiveContains("file path") {
                return L10n.string("auth.prompt.vertex.credentials_file", language: language)
            }
            if prompt.message.localizedCaseInsensitiveContains("project") {
                return L10n.string("auth.prompt.vertex.project", language: language)
            }
            return L10n.string("auth.prompt.vertex.location", language: language)
        case "cloudflare-ai-gateway", "cloudflare-workers-ai":
            if prompt.message.localizedCaseInsensitiveContains("gateway") {
                return L10n.string("auth.prompt.cloudflare.gateway", language: language)
            }
            return L10n.string("auth.prompt.cloudflare.account", language: language)
        case "github-copilot":
            return L10n.string("auth.github.host.title", language: language)
        default:
            return prompt.message
        }
    }
}

enum ProviderAuthenticationState: Equatable {
    case notConfigured
    case signedIn
    case credentialsSaved
    case externalCredentials
}

extension AgentHostProvider {
    var authenticationState: ProviderAuthenticationState {
        guard status.configured else { return .notConfigured }
        if status.source == .stored, status.credentialType == .oauth {
            return .signedIn
        }
        if status.source == .stored, status.credentialType == .apiKey {
            return .credentialsSaved
        }
        return .externalCredentials
    }
}

enum ProviderAuthFlowPhase: Equatable {
    case starting
    case waitingForProvider
    case waitingForUser
    case cancelling
    case succeeded
    case cancelled
    case failed

    var isTerminal: Bool {
        switch self {
        case .succeeded, .cancelled, .failed:
            return true
        case .starting, .waitingForProvider, .waitingForUser, .cancelling:
            return false
        }
    }
}

struct ProviderAuthDeviceCode: Equatable {
    let userCode: String
    let verificationURI: String
    let intervalSeconds: Int?
    let expiresInSeconds: Int?
}

struct ProviderAuthFlowState: Equatable, Identifiable {
    let id: String
    let providerId: String
    let providerName: String
    let method: AgentHostAuthMethod
    var phase: ProviderAuthFlowPhase
    var lastSequence: Int
    var prompt: AgentHostAuthPromptPayload?
    var authorizationURL: String?
    var authorizationInstructions: String?
    var deviceCode: ProviderAuthDeviceCode?
    var information: [String]
    var links: [AgentHostAuthInfoLink]
    var progressMessage: String?
    var isSubmitting: Bool
    var responseErrorMessage: String?
    var errorCode: String?
    var errorMessage: String?
}

enum ProviderAuthEffect: Equatable {
    case reloadProviders
}

struct ProviderAuthReducer {
    private(set) var flow: ProviderAuthFlowState?

    mutating func begin(
        flowId: String,
        provider: AgentHostProvider,
        method: AgentHostAuthMethod
    ) {
        flow = ProviderAuthFlowState(
            id: flowId,
            providerId: provider.id,
            providerName: provider.name,
            method: method,
            phase: .starting,
            lastSequence: 0,
            prompt: nil,
            authorizationURL: nil,
            authorizationInstructions: nil,
            deviceCode: nil,
            information: [],
            links: [],
            progressMessage: nil,
            isSubmitting: false,
            responseErrorMessage: nil,
            errorCode: nil,
            errorMessage: nil
        )
    }

    mutating func startAccepted(flowId: String) {
        guard var flow, flow.id == flowId, flow.phase == .starting else { return }
        flow.phase = .waitingForProvider
        self.flow = flow
    }

    mutating func responseAccepted(flowId: String, promptId: String) {
        guard var flow,
              flow.id == flowId,
              flow.prompt?.promptId == promptId else { return }
        flow.prompt = nil
        flow.phase = .waitingForProvider
        flow.isSubmitting = false
        flow.responseErrorMessage = nil
        self.flow = flow
    }

    mutating func responseStarted(flowId: String, promptId: String) {
        guard var flow,
              flow.id == flowId,
              flow.prompt?.promptId == promptId,
              !flow.isSubmitting else { return }
        flow.isSubmitting = true
        flow.responseErrorMessage = nil
        self.flow = flow
    }

    mutating func responseFailed(flowId: String, promptId: String, message: String) {
        guard var flow,
              flow.id == flowId,
              flow.prompt?.promptId == promptId else { return }
        flow.phase = .waitingForUser
        flow.isSubmitting = false
        flow.responseErrorMessage = message
        self.flow = flow
    }

    mutating func cancelRequested(flowId: String) {
        guard var flow, flow.id == flowId, !flow.phase.isTerminal else { return }
        flow.phase = .cancelling
        self.flow = flow
    }

    mutating func fail(flowId: String, code: String, message: String) {
        guard var flow, flow.id == flowId, !flow.phase.isTerminal else { return }
        flow.phase = .failed
        flow.prompt = nil
        clearTransientState(&flow)
        flow.errorCode = code
        flow.errorMessage = message
        self.flow = flow
    }

    mutating func clear() {
        flow = nil
    }

    mutating func apply(_ event: AgentHostServerEvent) -> [ProviderAuthEffect] {
        if case .modelsChanged = event {
            return [.reloadProviders]
        }

        guard var flow else { return [] }
        switch event {
        case .authPrompt(let payload):
            guard accepts(
                flow: flow,
                flowId: payload.flowId,
                providerId: payload.providerId,
                sequence: payload.sequence
            ) else { return [] }
            flow.lastSequence = payload.sequence
            flow.prompt = payload
            flow.phase = .waitingForUser
            flow.isSubmitting = false
            flow.responseErrorMessage = nil
        case .authPromptCancelled(let payload):
            guard accepts(
                flow: flow,
                flowId: payload.flowId,
                providerId: payload.providerId,
                sequence: payload.sequence
            ) else { return [] }
            flow.lastSequence = payload.sequence
            if flow.prompt?.promptId == payload.promptId {
                flow.prompt = nil
                flow.phase = .waitingForProvider
                flow.isSubmitting = false
                flow.responseErrorMessage = nil
            }
        case .authNotice(let payload):
            guard accepts(
                flow: flow,
                flowId: payload.flowId,
                providerId: payload.providerId,
                sequence: payload.sequence
            ) else { return [] }
            flow.lastSequence = payload.sequence
            switch payload.notice {
            case .info(let message, let links):
                flow.information.append(message)
                for link in links where !flow.links.contains(where: { $0.url == link.url }) {
                    flow.links.append(link)
                }
            case .authURL(let url, let instructions):
                flow.authorizationURL = url
                flow.authorizationInstructions = instructions
            case .deviceCode(
                let userCode,
                let verificationURI,
                let intervalSeconds,
                let expiresInSeconds
            ):
                flow.deviceCode = ProviderAuthDeviceCode(
                    userCode: userCode,
                    verificationURI: verificationURI,
                    intervalSeconds: intervalSeconds,
                    expiresInSeconds: expiresInSeconds
                )
            case .progress(let message):
                flow.progressMessage = message
            }
            if flow.prompt == nil, flow.phase != .cancelling {
                flow.phase = .waitingForProvider
            }
        case .authFinished(let payload):
            guard accepts(
                flow: flow,
                flowId: payload.flowId,
                providerId: payload.providerId,
                sequence: payload.sequence
            ) else { return [] }
            flow.lastSequence = payload.sequence
            flow.prompt = nil
            clearTransientState(&flow)
            switch payload.outcome {
            case .succeeded:
                flow.phase = .succeeded
            case .cancelled:
                flow.phase = .cancelled
            case .failed:
                flow.phase = .failed
                flow.errorCode = payload.error?.code
                flow.errorMessage = payload.error?.message
            }
            self.flow = flow
            return [.reloadProviders]
        case .hostHello,
             .sessionStateChanged,
             .sessionMessageDelta,
             .sessionUserContent,
             .sessionAssistantContent,
             .sessionToolStarted,
             .sessionToolUpdated,
             .sessionToolCompleted,
             .sessionApprovalRequested,
             .elicitationRequested,
             .sessionError,
             .sessionModeChanged,
             .sessionConfigOptionsChanged,
             .sessionInfoChanged,
             .sessionUsageChanged,
             .sessionAvailableCommandsChanged,
             .sessionPlanChanged,
             .sessionExtensionStatusChanged,
             .sessionExtensionWidgetChanged,
             .modelsChanged,
             .unknown:
            return []
        }
        self.flow = flow
        return []
    }

    private func clearTransientState(_ flow: inout ProviderAuthFlowState) {
        flow.authorizationURL = nil
        flow.authorizationInstructions = nil
        flow.deviceCode = nil
        flow.progressMessage = nil
        flow.isSubmitting = false
        flow.responseErrorMessage = nil
    }

    private func accepts(
        flow: ProviderAuthFlowState,
        flowId: String,
        providerId: String,
        sequence: Int
    ) -> Bool {
        flow.id == flowId
            && flow.providerId == providerId
            && sequence > flow.lastSequence
            && !flow.phase.isTerminal
    }
}

@MainActor
final class ProviderAuthStore: ObservableObject {
    @Published private(set) var providers: [AgentHostProvider] = []
    @Published private(set) var agentAuthMethods: [AgentHostACPAuthMethod] = []
    @Published private(set) var activeAgentAuthMethodID: String?
    @Published private(set) var isLoggingOutAgent = false
    @Published private(set) var flow: ProviderAuthFlowState?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: any ProviderAuthServicing
    private var reducer = ProviderAuthReducer()
    private var eventTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?

    init(service: any ProviderAuthServicing) {
        self.service = service
    }

    func start() async {
        if eventTask == nil {
            let events = await service.events()
            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    self?.receive(event)
                }
            }
        }
        if lifecycleTask == nil {
            let events = await service.lifecycleEvents()
            lifecycleTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    self?.receive(event)
                }
            }
        }
        await reloadAgentAuthenticationMethods()
        await reloadProviders()
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    func reloadProviders() async {
        isLoading = true
        defer { isLoading = false }
        do {
            providers = try await service.listProviders(requestID: UUID().uuidString)
            errorMessage = nil
        } catch AgentHostServiceError.missingPiWorkCapability(.providersList) {
            providers = []
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func reloadAgentAuthenticationMethods() async {
        do {
            agentAuthMethods = try await service.agentAuthenticationMethods()
        } catch {
            agentAuthMethods = []
            errorMessage = String(describing: error)
        }
    }

    func authenticateAgent(method: AgentHostACPAuthMethod) async {
        guard activeAgentAuthMethodID == nil, !isLoggingOutAgent else { return }
        activeAgentAuthMethodID = method.id
        defer { activeAgentAuthMethodID = nil }
        do {
            try await service.authenticateAgent(
                methodId: method.id,
                requestID: UUID().uuidString
            )
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func logoutAgent() async {
        guard activeAgentAuthMethodID == nil, !isLoggingOutAgent else { return }
        isLoggingOutAgent = true
        defer { isLoggingOutAgent = false }
        do {
            try await service.logoutAgent(requestID: UUID().uuidString)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func beginAuthentication(
        provider: AgentHostProvider,
        method: AgentHostAuthMethod
    ) async {
        guard flow?.phase.isTerminal != false else { return }
        let flowId = UUID().uuidString
        reducer.begin(flowId: flowId, provider: provider, method: method)
        publishFlow()
        do {
            _ = try await service.startAuthentication(
                flowId: flowId,
                providerId: provider.id,
                method: method,
                requestID: UUID().uuidString
            )
            reducer.startAccepted(flowId: flowId)
            publishFlow()
        } catch {
            reducer.fail(
                flowId: flowId,
                code: "auth_start_failed",
                message: L10n.string("auth.start_failed")
            )
            publishFlow()
        }
    }

    @discardableResult
    func respond(value: String) async -> Bool {
        guard let flow, let prompt = flow.prompt, !flow.isSubmitting else { return false }
        reducer.responseStarted(flowId: flow.id, promptId: prompt.promptId)
        publishFlow()
        do {
            _ = try await service.respondToAuthentication(
                flowId: flow.id,
                promptId: prompt.promptId,
                value: value,
                requestID: UUID().uuidString
            )
            reducer.responseAccepted(flowId: flow.id, promptId: prompt.promptId)
            publishFlow()
            return true
        } catch {
            reducer.responseFailed(
                flowId: flow.id,
                promptId: prompt.promptId,
                message: L10n.string("auth.response_failed")
            )
            publishFlow()
            return false
        }
    }

    func cancelAuthentication() async {
        guard let flow, !flow.phase.isTerminal else { return }
        reducer.cancelRequested(flowId: flow.id)
        publishFlow()
        do {
            _ = try await service.cancelAuthentication(
                flowId: flow.id,
                requestID: UUID().uuidString
            )
        } catch {
            reducer.fail(
                flowId: flow.id,
                code: "auth_cancel_failed",
                message: L10n.string("auth.cancel_failed")
            )
            publishFlow()
        }
    }

    func logout(provider: AgentHostProvider) async {
        do {
            let result = try await service.logoutProvider(
                providerId: provider.id,
                requestID: UUID().uuidString
            )
            if let index = providers.firstIndex(where: { $0.id == result.provider.id }) {
                providers[index] = result.provider
            }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func clearFlow() {
        guard flow?.phase.isTerminal != false else { return }
        reducer.clear()
        publishFlow()
    }

    private func receive(_ event: AgentHostServerEvent) {
        let effects = reducer.apply(event)
        publishFlow()
        for effect in effects {
            switch effect {
            case .reloadProviders:
                Task { await reloadProviders() }
            }
        }
    }

    private func receive(_ event: AgentHostServiceLifecycleEvent) {
        switch event {
        case .connected:
            return
        case .disconnected, .restarted:
            guard let flow, !flow.phase.isTerminal else { return }
            reducer.fail(
                flowId: flow.id,
                code: "auth_host_restarted",
                message: L10n.string("auth.host_restarted")
            )
            publishFlow()
        }
    }

    private func publishFlow() {
        flow = reducer.flow
    }
}

@MainActor
final class AgentSettingsStore: ObservableObject {
    @Published private(set) var settings: AgentHostSettings?
    @Published private(set) var models: [AgentHostModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?

    private let service: any AgentSettingsServicing

    init(service: any AgentSettingsServicing) {
        self.service = service
    }

    func start() async {
        guard settings == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedSettings = service.getAgentSettings(requestID: UUID().uuidString)
            async let loadedModels = service.listModels(requestID: UUID().uuidString)
            settings = try await loadedSettings
            models = try await loadedModels
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func update(_ patch: AgentHostSettingsPatch) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            settings = try await service.updateAgentSettings(
                patch,
                requestID: UUID().uuidString
            )
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func reload() async {
        settings = nil
        await start()
    }
}
