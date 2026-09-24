import XCTest
@testable import PiWork

final class ProviderAuthStoreTests: XCTestCase {
    func testBedrockCredentialHelpExplainsTheStandardCredentialChain() {
        XCTAssertEqual(
            ProviderAuthenticationGuide.credentialHelpURL(for: "amazon-bedrock")?.absoluteString,
            "https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html"
        )
    }

    func testAuthenticationViewGuidesEveryInteractiveCredentialPath() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )
        let requiredBehavior = [
            "auth.method.choose",
            "auth.browser.help",
            "auth.browser.open_failed",
            "auth.device.help",
            "auth.device.copied",
            "auth.device.expires_seconds",
            "auth.credentials.title",
            "auth.credentials.help",
            "auth.credentials.open_help",
            "auth.credentials.storage",
            "auth.retry",
            ".onChange(of: flow?.deviceCode?.verificationURI)",
            "ProviderAuthenticationGuide.webURL",
            "ProviderAuthenticationGuide.credentialHelpURL",
        ]

        for behavior in requiredBehavior {
            XCTAssertTrue(source.contains(behavior), "Missing authentication behavior: \(behavior)")
        }
    }

    func testProviderSettingsAlsoExposesStandardACPAgentAuthentication() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "PiWork/Core/Agent/ProviderAuthStore.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("AgentAuthenticationSection"))
        XCTAssertTrue(source.contains("agentAuthMethods"))
        XCTAssertTrue(storeSource.contains("authenticateAgent"))
        XCTAssertTrue(storeSource.contains("logoutAgent"))
    }

    func testAuthenticationViewExposesRetryableAndHonestInteractionStates() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )
        let requiredBehavior = [
            "provider.authenticationState",
            "providers.status.credentials_saved",
            "providers.status.not_verified",
            "providers.models_supported",
            "responseErrorMessage",
            "flow.errorMessage ??",
            "isSubmitting",
            "if await store.respond(value: value)",
            "@FocusState",
            ".accessibilityLabel(promptTitle",
            ".keyboardShortcut(.cancelAction)",
            "if !flow.phase.isTerminal, let url = flow.authorizationURL",
            "if !flow.phase.isTerminal, let code = flow.deviceCode",
            "if !flow.phase.isTerminal, let externalActionError",
        ]

        for behavior in requiredBehavior {
            XCTAssertTrue(source.contains(behavior), "Missing interaction behavior: \(behavior)")
        }
        XCTAssertFalse(
            source.contains("case .stored: return L10n.string(\"providers.status.connected\")"),
            "Stored API keys must not be described as a verified connection"
        )
    }

    func testKnownProviderPromptsArePresentedInTheSelectedLanguage() {
        let azureEndpoint = AgentHostAuthPromptPayload(
            flowId: "flow",
            providerId: "azure-openai-responses",
            sequence: 1,
            promptId: "prompt",
            type: .text,
            message: "Enter Azure OpenAI resource URL",
            placeholder: nil,
            options: nil,
            allowsEmpty: nil
        )
        let bedrockMethod = AgentHostAuthPromptPayload(
            flowId: "flow",
            providerId: "amazon-bedrock",
            sequence: 1,
            promptId: "prompt",
            type: .select,
            message: "Select Amazon Bedrock authentication method:",
            placeholder: nil,
            options: nil,
            allowsEmpty: nil
        )
        let manualCode = AgentHostAuthPromptPayload(
            flowId: "flow",
            providerId: "openai-codex",
            sequence: 1,
            promptId: "prompt",
            type: .manualCode,
            message: "Paste the authorization code",
            placeholder: nil,
            options: nil,
            allowsEmpty: nil
        )

        XCTAssertEqual(
            ProviderAuthenticationPresentation.promptTitle(
                providerName: "Azure OpenAI",
                prompt: azureEndpoint,
                language: .simplifiedChinese
            ),
            "输入 Azure OpenAI 资源 URL"
        )
        XCTAssertEqual(
            ProviderAuthenticationPresentation.promptTitle(
                providerName: "Amazon Bedrock",
                prompt: bedrockMethod,
                language: .simplifiedChinese
            ),
            "选择 Amazon Bedrock 认证方式"
        )
        XCTAssertEqual(
            ProviderAuthenticationPresentation.promptTitle(
                providerName: "OpenAI Codex",
                prompt: manualCode,
                language: .simplifiedChinese
            ),
            "粘贴授权码或回调地址"
        )
        XCTAssertEqual(
            ProviderAuthenticationPresentation.optionTitle(
                id: "credential-chain",
                fallback: "Existing AWS credential chain",
                language: .simplifiedChinese
            ),
            "现有 AWS 凭证链"
        )
        XCTAssertEqual(
            ProviderAuthenticationPresentation.errorMessage(
                code: "login_failed",
                fallback: "Authentication could not be completed.",
                language: .simplifiedChinese
            ),
            "认证未完成。请检查网络连接或凭据，然后重试。"
        )
    }

    func testGitHubCopilotHostPromptOffersAnObviousGithubDotComPath() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )
        let requiredBehavior = [
            "prompt.allowsEmpty == true",
            "auth.github.host.title",
            "auth.github.host.github_com",
            "auth.github.host.enterprise",
            "auth.github.host.enterprise_help",
            "auth.github.host.enterprise_label",
            "auth.github.host.enterprise_continue",
            "showsGitHubEnterprise",
            "submit(\"\")",
        ]

        for behavior in requiredBehavior {
            XCTAssertTrue(source.contains(behavior), "Missing GitHub Copilot host behavior: \(behavior)")
        }
    }

    func testEveryBuiltInCredentialProviderHasAnOfficialHelpDestination() throws {
        let providerIDs = [
            "amazon-bedrock", "ant-ling", "anthropic", "azure-openai-responses", "baseten",
            "cerebras", "cloudflare-ai-gateway", "cloudflare-workers-ai", "deepseek",
            "fireworks", "github-copilot", "google", "google-vertex", "groq", "huggingface",
            "kimi-coding", "minimax", "minimax-cn", "mistral", "moonshotai", "moonshotai-cn",
            "nvidia", "openai", "opencode", "opencode-go", "openrouter", "qwen-token-plan",
            "qwen-token-plan-cn", "qwen-token-plan-individual", "radius", "together",
            "vercel-ai-gateway", "xai", "xiaomi", "xiaomi-token-plan-ams",
            "xiaomi-token-plan-cn", "xiaomi-token-plan-sgp", "zai", "zai-coding-cn",
        ]

        for providerID in providerIDs {
            let url = try XCTUnwrap(
                ProviderAuthenticationGuide.credentialHelpURL(for: providerID),
                "Missing credential help for \(providerID)"
            )
            XCTAssertEqual(url.scheme, "https", "Credential help must use HTTPS for \(providerID)")
            XCTAssertNotNil(url.host, "Credential help must include a host for \(providerID)")
        }
        XCTAssertNil(ProviderAuthenticationGuide.credentialHelpURL(for: "custom-provider"))
    }

    func testAuthenticationGuideAcceptsOnlyWebURLsWithHosts() {
        XCTAssertEqual(
            ProviderAuthenticationGuide.webURL(from: "  HTTPS://example.com/login  ")?.host,
            "example.com"
        )
        XCTAssertNotNil(ProviderAuthenticationGuide.webURL(from: "http://localhost:8080/device"))
        XCTAssertNil(ProviderAuthenticationGuide.webURL(from: "javascript:alert(1)"))
        XCTAssertNil(ProviderAuthenticationGuide.webURL(from: "file:///tmp/credentials"))
        XCTAssertNil(ProviderAuthenticationGuide.webURL(from: "/relative/login"))
        XCTAssertNil(ProviderAuthenticationGuide.webURL(from: "https:///missing-host"))
    }

    func testReducerKeepsAuthorizationURLWhilePresentingManualCodePrompt() {
        var reducer = ProviderAuthReducer()
        reducer.begin(
            flowId: "flow-one",
            provider: makeProvider(),
            method: .oauth
        )

        _ = reducer.apply(
            .authNotice(
                AgentHostAuthNoticePayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 1,
                    notice: .authURL(
                        url: "https://example.com/oauth",
                        instructions: "Continue in your browser"
                    )
                )
            )
        )
        _ = reducer.apply(
            .authPrompt(
                AgentHostAuthPromptPayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 2,
                    promptId: "prompt-one",
                    type: .manualCode,
                    message: "Paste the authorization code",
                    placeholder: "Code",
                    options: nil,
                    allowsEmpty: nil
                )
            )
        )

        XCTAssertEqual(reducer.flow?.authorizationURL, "https://example.com/oauth")
        XCTAssertEqual(reducer.flow?.authorizationInstructions, "Continue in your browser")
        XCTAssertEqual(reducer.flow?.prompt?.promptId, "prompt-one")
        XCTAssertEqual(reducer.flow?.prompt?.type, .manualCode)
        XCTAssertEqual(reducer.flow?.phase, .waitingForUser)
    }

    func testReducerCancelsOnlyTheMatchingPromptAndFinishesFlowSeparately() {
        var reducer = ProviderAuthReducer()
        reducer.begin(
            flowId: "flow-one",
            provider: makeProvider(),
            method: .oauth
        )
        _ = reducer.apply(
            .authPrompt(
                AgentHostAuthPromptPayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 1,
                    promptId: "prompt-one",
                    type: .secret,
                    message: "API key",
                    placeholder: nil,
                    options: nil,
                    allowsEmpty: nil
                )
            )
        )

        _ = reducer.apply(
            .authPromptCancelled(
                AgentHostAuthPromptCancelledPayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 2,
                    promptId: "different-prompt"
                )
            )
        )
        XCTAssertEqual(reducer.flow?.prompt?.promptId, "prompt-one")

        _ = reducer.apply(
            .authPromptCancelled(
                AgentHostAuthPromptCancelledPayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 3,
                    promptId: "prompt-one"
                )
            )
        )
        XCTAssertNil(reducer.flow?.prompt)
        XCTAssertEqual(reducer.flow?.phase, .waitingForProvider)

        let effects = reducer.apply(
            .authFinished(
                AgentHostAuthFinishedPayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 4,
                    outcome: .succeeded,
                    error: nil
                )
            )
        )
        XCTAssertEqual(reducer.flow?.phase, .succeeded)
        XCTAssertEqual(effects, [.reloadProviders])
    }

    func testReducerRestoresThePromptAfterAResponseFailure() {
        var reducer = ProviderAuthReducer()
        reducer.begin(flowId: "flow-one", provider: makeProvider(), method: .apiKey)
        let prompt = AgentHostAuthPromptPayload(
            flowId: "flow-one",
            providerId: "openai-codex",
            sequence: 1,
            promptId: "prompt-one",
            type: .secret,
            message: "API key",
            placeholder: nil,
            options: nil,
            allowsEmpty: nil
        )
        _ = reducer.apply(.authPrompt(prompt))

        reducer.responseStarted(flowId: "flow-one", promptId: "prompt-one")
        XCTAssertTrue(reducer.flow?.isSubmitting == true)

        reducer.responseFailed(
            flowId: "flow-one",
            promptId: "prompt-one",
            message: "Could not submit the response. Try again."
        )

        XCTAssertEqual(reducer.flow?.phase, .waitingForUser)
        XCTAssertEqual(reducer.flow?.prompt, prompt)
        XCTAssertFalse(reducer.flow?.isSubmitting == true)
        XCTAssertEqual(
            reducer.flow?.responseErrorMessage,
            "Could not submit the response. Try again."
        )
    }

    func testReducerClearsTransientBrowserStateAndKeepsTheSafeFailureCode() {
        var reducer = ProviderAuthReducer()
        reducer.begin(flowId: "flow-one", provider: makeProvider(), method: .oauth)
        _ = reducer.apply(.authNotice(AgentHostAuthNoticePayload(
            flowId: "flow-one",
            providerId: "openai-codex",
            sequence: 1,
            notice: .authURL(url: "https://example.com/oauth", instructions: nil)
        )))

        _ = reducer.apply(.authFinished(AgentHostAuthFinishedPayload(
            flowId: "flow-one",
            providerId: "openai-codex",
            sequence: 2,
            outcome: .failed,
            error: AgentHostResponseError(
                code: "auth_network_failed",
                message: "Could not reach the authentication service."
            )
        )))

        XCTAssertEqual(reducer.flow?.phase, .failed)
        XCTAssertEqual(reducer.flow?.errorCode, "auth_network_failed")
        XCTAssertEqual(
            reducer.flow?.errorMessage,
            "Could not reach the authentication service."
        )
        XCTAssertNil(reducer.flow?.authorizationURL)
        XCTAssertNil(reducer.flow?.authorizationInstructions)
        XCTAssertNil(reducer.flow?.deviceCode)
    }

    func testProviderConfigurationStateDoesNotCallSavedAPIKeysSignedIn() {
        let savedKey = makeProvider(
            method: .apiKey,
            configured: true,
            source: .stored,
            credentialType: .apiKey
        )
        let signedIn = makeProvider(
            method: .oauth,
            configured: true,
            source: .stored,
            credentialType: .oauth
        )
        let external = makeProvider(
            method: .apiKey,
            configured: true,
            source: .environment,
            credentialType: nil
        )

        XCTAssertEqual(savedKey.authenticationState, .credentialsSaved)
        XCTAssertEqual(signedIn.authenticationState, .signedIn)
        XCTAssertEqual(external.authenticationState, .externalCredentials)
        XCTAssertEqual(makeProvider().authenticationState, .notConfigured)
    }

    @MainActor
    func testStoreKeepsThePromptRetryableWhenRespondingFails() async {
        let host = FakeProviderAuthHost(providers: [makeProvider()], failResponses: true)
        let store = ProviderAuthStore(service: host)
        await store.start()
        await store.beginAuthentication(provider: makeProvider(), method: .oauth)
        let flowID = try! XCTUnwrap(store.flow?.id)
        let prompt = AgentHostAuthPromptPayload(
            flowId: flowID,
            providerId: "openai-codex",
            sequence: 1,
            promptId: "prompt-one",
            type: .manualCode,
            message: "Paste code",
            placeholder: nil,
            options: nil,
            allowsEmpty: nil
        )
        await host.emit(.authPrompt(prompt))
        await waitUntil { store.flow?.prompt?.promptId == "prompt-one" }

        let accepted = await store.respond(value: "keep-this-code")

        XCTAssertFalse(accepted)
        XCTAssertEqual(store.flow?.prompt, prompt)
        XCTAssertEqual(store.flow?.phase, .waitingForUser)
        XCTAssertFalse(store.flow?.isSubmitting == true)
        XCTAssertEqual(
            store.flow?.responseErrorMessage,
            L10n.string("auth.response_failed")
        )
        XCTAssertNil(store.errorMessage)
        let responses = await host.responses
        XCTAssertEqual(responses, ["keep-this-code"])
        store.stop()
    }

    @MainActor
    func testStoreEndsAnActiveFlowWhenTheHostDisconnects() async {
        let host = FakeProviderAuthHost(providers: [makeProvider()])
        let store = ProviderAuthStore(service: host)
        await store.start()
        await store.beginAuthentication(provider: makeProvider(), method: .oauth)

        await host.emitLifecycle(.disconnected(generation: 1, error: .connectionLost))
        await waitUntil { store.flow?.phase == .failed }

        XCTAssertEqual(store.flow?.errorCode, "auth_host_restarted")
        XCTAssertEqual(store.flow?.errorMessage, L10n.string("auth.host_restarted"))
        store.stop()
    }

    @MainActor
    func testStoreLoadsProvidersAndStartsAuthentication() async {
        let host = FakeProviderAuthHost(providers: [makeProvider()])
        let store = ProviderAuthStore(service: host)

        await store.start()
        await store.beginAuthentication(provider: makeProvider(), method: .oauth)

        XCTAssertEqual(store.providers.map(\.id), ["openai-codex"])
        XCTAssertEqual(store.flow?.providerId, "openai-codex")
        XCTAssertEqual(store.flow?.phase, .waitingForProvider)
        let starts = await host.starts
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.providerId, "openai-codex")
        XCTAssertEqual(starts.first?.method, .oauth)
        store.stop()
    }

    private func makeProvider(
        method: AgentHostAuthMethod = .oauth,
        configured: Bool = false,
        source: AgentHostProviderAuthSource? = nil,
        credentialType: AgentHostAuthMethod? = nil
    ) -> AgentHostProvider {
        AgentHostProvider(
            id: "openai-codex",
            name: "OpenAI Codex",
            methods: [
                AgentHostProviderAuthMethod(
                    type: method,
                    name: "OpenAI Codex OAuth",
                    loginLabel: "Sign in with ChatGPT"
                )
            ],
            status: AgentHostProviderAuthStatus(
                configured: configured,
                source: source,
                credentialType: credentialType,
                canDisconnect: source == .stored,
                label: nil
            ),
            models: AgentHostProviderModelCounts(total: 4, available: 0)
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<50 {
            if predicate() { return }
            await Task.yield()
        }
    }
}

final class AgentSettingsStoreTests: XCTestCase {
    @MainActor
    func testStoreLoadsModelsAndPersistsASettingsPatch() async {
        let initial = AgentHostSettings(
            defaultModel: AgentHostDefaultModel(provider: "openai", modelId: "gpt-test"),
            defaultThinkingLevel: .high,
            transport: .auto,
            compactionEnabled: true,
            retryEnabled: true
        )
        let model = AgentHostModel(
            provider: "openai",
            id: "gpt-test",
            name: "GPT Test",
            contextWindow: 128_000,
            maxTokens: 16_384,
            reasoning: true,
            supportsImages: true
        )
        let host = FakeAgentSettingsHost(settings: initial, models: [model])
        let store = AgentSettingsStore(service: host)

        await store.start()
        await store.update(
            AgentHostSettingsPatch(
                defaultThinkingLevel: .max,
                compactionEnabled: false
            )
        )

        XCTAssertEqual(store.models, [model])
        XCTAssertEqual(store.settings?.defaultThinkingLevel, .max)
        XCTAssertEqual(store.settings?.compactionEnabled, false)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isSaving)
        XCTAssertNil(store.errorMessage)
        let patches = await host.patches
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].defaultThinkingLevel, .max)
        XCTAssertEqual(patches[0].compactionEnabled, false)
    }
}

private actor FakeProviderAuthHost: ProviderAuthServicing {
    struct Start: Equatable {
        let flowId: String
        let providerId: String
        let method: AgentHostAuthMethod
    }

    private let providersValue: [AgentHostProvider]
    private let stream: AsyncStream<AgentHostServerEvent>
    private let continuation: AsyncStream<AgentHostServerEvent>.Continuation
    private let lifecycleStream: AsyncStream<AgentHostServiceLifecycleEvent>
    private let lifecycleContinuation: AsyncStream<AgentHostServiceLifecycleEvent>.Continuation
    private let failResponses: Bool
    private(set) var starts: [Start] = []
    private(set) var responses: [String] = []

    init(providers: [AgentHostProvider], failResponses: Bool = false) {
        providersValue = providers
        self.failResponses = failResponses
        var storedContinuation: AsyncStream<AgentHostServerEvent>.Continuation!
        stream = AsyncStream { storedContinuation = $0 }
        continuation = storedContinuation
        var storedLifecycleContinuation: AsyncStream<AgentHostServiceLifecycleEvent>.Continuation!
        lifecycleStream = AsyncStream { storedLifecycleContinuation = $0 }
        lifecycleContinuation = storedLifecycleContinuation
    }

    func events() -> AsyncStream<AgentHostServerEvent> { stream }

    func lifecycleEvents() -> AsyncStream<AgentHostServiceLifecycleEvent> { lifecycleStream }

    func emit(_ event: AgentHostServerEvent) {
        continuation.yield(event)
    }

    func emitLifecycle(_ event: AgentHostServiceLifecycleEvent) {
        lifecycleContinuation.yield(event)
    }

    func listProviders(requestID: String) async throws -> [AgentHostProvider] {
        providersValue
    }

    func startAuthentication(
        flowId: String,
        providerId: String,
        method: AgentHostAuthMethod,
        requestID: String
    ) async throws -> AgentHostAuthStartResult {
        starts.append(Start(flowId: flowId, providerId: providerId, method: method))
        return AgentHostAuthStartResult(accepted: true, flowId: flowId)
    }

    func respondToAuthentication(
        flowId: String,
        promptId: String,
        value: String,
        requestID: String
    ) async throws -> AgentHostAuthAcceptedResult {
        responses.append(value)
        if failResponses { throw FakeError.responseFailed }
        return AgentHostAuthAcceptedResult(accepted: true)
    }

    func cancelAuthentication(
        flowId: String,
        requestID: String
    ) async throws -> AgentHostAuthCancelResult {
        AgentHostAuthCancelResult(cancelRequested: true)
    }

    func logoutProvider(
        providerId: String,
        requestID: String
    ) async throws -> AgentHostAuthLogoutResult {
        AgentHostAuthLogoutResult(removed: false, provider: providersValue[0])
    }

    private enum FakeError: Error {
        case responseFailed
    }
}

private actor FakeAgentSettingsHost: AgentSettingsServicing {
    private var settingsValue: AgentHostSettings
    private let modelsValue: [AgentHostModel]
    private(set) var patches: [AgentHostSettingsPatch] = []

    init(settings: AgentHostSettings, models: [AgentHostModel]) {
        settingsValue = settings
        modelsValue = models
    }

    func listModels(requestID: String) async throws -> [AgentHostModel] {
        modelsValue
    }

    func getAgentSettings(requestID: String) async throws -> AgentHostSettings {
        settingsValue
    }

    func updateAgentSettings(
        _ patch: AgentHostSettingsPatch,
        requestID: String
    ) async throws -> AgentHostSettings {
        patches.append(patch)
        settingsValue = AgentHostSettings(
            defaultModel: patch.defaultModel ?? settingsValue.defaultModel,
            defaultThinkingLevel: patch.defaultThinkingLevel ?? settingsValue.defaultThinkingLevel,
            transport: patch.transport ?? settingsValue.transport,
            compactionEnabled: patch.compactionEnabled ?? settingsValue.compactionEnabled,
            retryEnabled: patch.retryEnabled ?? settingsValue.retryEnabled
        )
        return settingsValue
    }
}
