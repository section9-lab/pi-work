import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppSettingsView: View {
    @ObservedObject var agentSettingsStore: AgentSettingsStore
    @ObservedObject var providerAuthStore: ProviderAuthStore
    @ObservedObject var installedExtensionsStore: InstalledExtensionsStore
    @ObservedObject var languageStore: LanguageStore
    @ObservedObject var updateController: AppUpdateController
    @StateObject private var piCodingAgentUpdateController = AppUpdateController.piCodingAgent()
    @StateObject private var globalInstructionsStore = GlobalAgentInstructionsStore.applicationDefault()
    @State private var selection: SettingsDestination? = .general

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selection, language: languageStore.language)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general:
                    GeneralSettingsView(
                        languageStore: languageStore,
                        piCodingAgentUpdateController: piCodingAgentUpdateController,
                        updateController: updateController
                    )
                case .agent:
                    AgentGeneralSettingsView(store: agentSettingsStore)
                case .extensions:
                    ExtensionSettingsView(store: installedExtensionsStore)
                case .personalPreferences:
                    GlobalAgentInstructionsSettingsView()
                case .modelsAndAuthentication:
                    ModelProviderSettingsView(store: providerAuthStore)
                case .experiments:
                    ExperimentsSettingsView()
                }
            }
            .navigationTitle((selection ?? .general).title(language: languageStore.language))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environmentObject(globalInstructionsStore)
        }
        .frame(minWidth: 656, idealWidth: 720, minHeight: 560, idealHeight: 620)
        .task {
            await agentSettingsStore.start()
            globalInstructionsStore.load()
        }
    }
}

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case agent
    case extensions
    case personalPreferences
    case modelsAndAuthentication
    case experiments

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .general:
            return L10n.string("settings.sidebar.general", language: language)
        case .agent:
            return L10n.string("settings.sidebar.agent", language: language)
        case .extensions:
            return L10n.string("settings.sidebar.extensions", language: language)
        case .personalPreferences:
            return L10n.string("settings.sidebar.personal_preferences", language: language)
        case .modelsAndAuthentication:
            return L10n.string("settings.sidebar.models_auth", language: language)
        case .experiments:
            return L10n.string("settings.sidebar.experiments", language: language)
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .agent: return "slider.horizontal.3"
        case .extensions: return "puzzlepiece.extension"
        case .personalPreferences: return "person.text.rectangle"
        case .modelsAndAuthentication: return "key.horizontal"
        case .experiments: return "flask"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsDestination?
    let language: AppLanguage

    var body: some View {
        List(selection: $selection) {
            Label(SettingsDestination.general.title(language: language), systemImage: "gearshape")
                .tag(SettingsDestination.general)

            Section(L10n.string("settings.sidebar.section", language: language)) {
                ForEach(SettingsDestination.allCases.filter { $0 != .general }) { destination in
                    Label(destination.title(language: language), systemImage: destination.icon)
                        .tag(destination)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text(L10n.string("settings.sidebar.isolated", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
        }
    }
}

private struct GlobalAgentInstructionsSettingsView: View {
    @EnvironmentObject private var store: GlobalAgentInstructionsStore

    var body: some View {
        Form {
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .textSelection(.enabled)
                    Button(L10n.string("common.retry")) { store.load() }
                }
            }

            Section {
                LabeledContent("AGENTS.md") {
                    Text(store.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(store.fileURL.path)
                }

                AlignedPlaceholderTextEditor(
                    text: $store.draft,
                    placeholder: L10n.string("settings.personal_preferences.placeholder")
                )
                .frame(minHeight: 280)
                .accessibilityLabel(L10n.string("settings.personal_preferences.title"))

                HStack {
                    if store.didSave {
                        Label(L10n.string("settings.personal_preferences.saved"), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.string("settings.personal_preferences.revert")) { store.revert() }
                        .disabled(!store.hasUnsavedChanges || store.isSaving)
                    Button(L10n.string("settings.personal_preferences.save")) { store.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!store.hasUnsavedChanges || store.isSaving)
                }
            } header: {
                Text(L10n.string("settings.personal_preferences.subtitle"))
            } footer: {
                Text(L10n.string("settings.personal_preferences.changes_apply"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlignedPlaceholderTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay

        let textView = PlaceholderTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.placeholder = placeholder
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        context.coordinator.parent = self
        textView.placeholder = placeholder
        if textView.string != text {
            textView.string = text
        }
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AlignedPlaceholderTextEditor

        init(_ parent: AlignedPlaceholderTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let origin = textContainerOrigin
        let availableWidth = max(0, bounds.width - origin.x - textContainerInset.width)
        (placeholder as NSString).draw(
            with: NSRect(
                x: origin.x,
                y: origin.y,
                width: availableWidth,
                height: bounds.height - origin.y
            ),
            options: [.usesLineFragmentOrigin],
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
    }
}

private struct ExperimentsSettingsView: View {
    var body: some View {
        Form {
            Section {
                Toggle(isOn: .constant(false)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("settings.experiments.computer_use.title"))
                        Text(L10n.string("settings.experiments.computer_use.description"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel(L10n.string("settings.experiments.computer_use.title"))
                .disabled(true)
            } header: {
                Text(L10n.string("settings.experiments.subtitle"))
            } footer: {
                Text(L10n.string("settings.experiments.coming_soon"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var languageStore: LanguageStore
    @ObservedObject var piCodingAgentUpdateController: AppUpdateController
    @ObservedObject var updateController: AppUpdateController

    var body: some View {
        Form {
            Section {
                Picker(selection: $languageStore.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("settings.general.language.title"))
                        Text(L10n.string("settings.general.language.description"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel(L10n.string("settings.general.language.title"))
            } header: {
                Text(L10n.string("settings.general.subtitle"))
            }

            Section {
                AppUpdateSettingsRow(controller: updateController)
                PiCodingAgentUpdateSettingsRow(controller: piCodingAgentUpdateController)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PiCodingAgentUpdateSettingsRow: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        AgentSettingsRow(
            title: "pi-coding-agent",
            description: statusDescription
        ) {
            if controller.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .help(L10n.string("update.agent.checking"))
            } else {
                Button(buttonTitle) {
                    if case .updateAvailable = controller.state {
                        controller.openAvailableUpdate()
                    } else {
                        Task { await controller.checkForUpdates() }
                    }
                }
                .disabled(controller.currentVersion.isEmpty)
            }
        }
    }

    private var statusDescription: String {
        guard !controller.currentVersion.isEmpty else {
            return L10n.string("update.agent.version_unavailable")
        }
        switch controller.state {
        case .idle:
            return L10n.format("update.installed_version", controller.currentVersion)
        case .checking:
            return L10n.string("update.agent.checking")
        case .upToDate:
            return L10n.format("update.agent.status.up_to_date", controller.currentVersion)
        case let .updateAvailable(update):
            return L10n.format("update.agent.status.available", update.version)
        case .failed:
            return L10n.string("update.agent.status.failed")
        }
    }

    private var buttonTitle: String {
        if case .updateAvailable = controller.state {
            return L10n.string("update.agent.changelog")
        }
        return L10n.string("update.check")
    }
}

private struct AppUpdateSettingsRow: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        AgentSettingsRow(
            title: L10n.string("update.title"),
            description: statusDescription
        ) {
            if controller.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .help(L10n.string("update.checking"))
            } else {
                Button(buttonTitle) {
                    if case .updateAvailable = controller.state {
                        controller.openAvailableUpdate()
                    } else {
                        Task { await controller.checkForUpdatesAndPresent() }
                    }
                }
            }
        }
    }

    private var statusDescription: String {
        switch controller.state {
        case .idle:
            return L10n.format("update.installed_version", controller.currentVersion)
        case .checking:
            return L10n.string("update.checking")
        case .upToDate:
            return L10n.format("update.status.up_to_date", controller.currentVersion)
        case let .updateAvailable(update):
            return L10n.format("update.status.available", update.version)
        case .failed:
            return L10n.string("update.status.failed")
        }
    }

    private var buttonTitle: String {
        if case .updateAvailable = controller.state {
            return L10n.string("update.download")
        }
        return L10n.string("update.check")
    }
}

private struct AgentGeneralSettingsView: View {
    @ObservedObject var store: AgentSettingsStore

    var body: some View {
        Form {
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .textSelection(.enabled)
                    Button(L10n.string("common.retry")) { Task { await store.reload() } }
                }
            }

            if store.isLoading && store.settings == nil {
                ProgressView(L10n.string("settings.agent.loading"))
            } else if store.settings != nil {
                settingsContent
                    .disabled(store.isSaving)
            } else {
                Section {
                    Label(L10n.string("settings.agent.unavailable"), systemImage: "slider.horizontal.3")
                    Button(L10n.string("common.retry")) { Task { await store.reload() } }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var settingsContent: some View {
        Section {
            Picker(selection: modelSelection) {
                Text(L10n.string("settings.agent.default_model.select")).tag("")
                ForEach(sortedModels) { model in
                    Text("\(model.name) · \(model.provider)").tag(modelKey(model))
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("settings.agent.default_model.title"))
                    Text(L10n.string("settings.agent.default_model.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(L10n.string("settings.agent.default_model.title"))

            Picker(selection: thinkingSelection) {
                ForEach(AgentHostThinkingLevel.allCases) { level in
                    Text(level.settingsTitle).tag(level)
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("settings.agent.thinking.title"))
                    Text(L10n.string("settings.agent.thinking.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(L10n.string("settings.agent.thinking.title"))
        } header: {
            Text(L10n.string("settings.agent.session_defaults.title"))
        } footer: {
            Text(L10n.string("settings.agent.session_defaults.subtitle"))
        }

        Section {
            Toggle(isOn: compactionSelection) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("settings.agent.compaction.title"))
                    Text(L10n.string("settings.agent.compaction.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityLabel(L10n.string("settings.agent.compaction.title"))

            Toggle(isOn: retrySelection) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("settings.agent.retry.title"))
                    Text(L10n.string("settings.agent.retry.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityLabel(L10n.string("settings.agent.retry.title"))
        } header: {
            Text(L10n.string("settings.agent.runtime.title"))
        } footer: {
            Text(L10n.string("settings.agent.runtime.subtitle"))
        }

        Section {
            Picker(selection: transportSelection) {
                ForEach(AgentHostTransport.allCases) { transport in
                    Text(transport.settingsTitle).tag(transport)
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("settings.agent.transport.title"))
                    Text(L10n.string("settings.agent.transport.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(L10n.string("settings.agent.transport.title"))
        } header: {
            Text(L10n.string("settings.agent.connection.title"))
        } footer: {
            Text(L10n.string("settings.agent.connection.subtitle"))
            Text(L10n.string("settings.agent.changes_apply"))
        }
    }

    private var sortedModels: [AgentHostModel] {
        store.models.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.provider.localizedStandardCompare(rhs.provider) == .orderedAscending
        }
    }

    private func modelKey(_ model: AgentHostModel) -> String {
        "\(model.provider)\u{1F}\(model.id)"
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                guard let model = store.settings?.defaultModel else { return "" }
                return "\(model.provider)\u{1F}\(model.modelId)"
            },
            set: { key in
                guard let model = store.models.first(where: { modelKey($0) == key }) else { return }
                Task {
                    await store.update(AgentHostSettingsPatch(
                        defaultModel: AgentHostDefaultModel(
                            provider: model.provider,
                            modelId: model.id
                        )
                    ))
                }
            }
        )
    }

    private var thinkingSelection: Binding<AgentHostThinkingLevel> {
        Binding(
            get: { store.settings?.defaultThinkingLevel ?? .off },
            set: { level in
                Task { await store.update(AgentHostSettingsPatch(defaultThinkingLevel: level)) }
            }
        )
    }

    private var transportSelection: Binding<AgentHostTransport> {
        Binding(
            get: { store.settings?.transport ?? .auto },
            set: { transport in
                Task { await store.update(AgentHostSettingsPatch(transport: transport)) }
            }
        )
    }

    private var compactionSelection: Binding<Bool> {
        Binding(
            get: { store.settings?.compactionEnabled ?? true },
            set: { enabled in
                Task { await store.update(AgentHostSettingsPatch(compactionEnabled: enabled)) }
            }
        )
    }

    private var retrySelection: Binding<Bool> {
        Binding(
            get: { store.settings?.retryEnabled ?? true },
            set: { enabled in
                Task { await store.update(AgentHostSettingsPatch(retryEnabled: enabled)) }
            }
        )
    }
}

private struct AgentSettingsRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder let control: Control

    init(title: String, description: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control
                .accessibilityLabel(title)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension AgentHostThinkingLevel {
    var settingsTitle: String {
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

private extension AgentHostTransport {
    var settingsTitle: String {
        switch self {
        case .auto: return L10n.string("settings.transport.auto")
        case .sse: return "SSE"
        case .websocket: return "WebSocket"
        case .websocketCached: return L10n.string("settings.transport.websocket_cached")
        }
    }
}

struct ModelProviderSettingsView: View {
    @ObservedObject var store: ProviderAuthStore
    @State private var disconnectCandidate: AgentHostProvider?

    private var sortedProviders: [AgentHostProvider] {
        store.providers.sorted { lhs, rhs in
            if lhs.status.configured != rhs.status.configured {
                return lhs.status.configured
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .textSelection(.enabled)
                    Button(L10n.string("common.retry")) {
                        Task { await store.reloadProviders() }
                    }
                }
            }

            if !store.agentAuthMethods.isEmpty {
                AgentAuthenticationSection(
                    methods: store.agentAuthMethods,
                    activeMethodID: store.activeAgentAuthMethodID,
                    isLoggingOut: store.isLoggingOutAgent,
                    onAuthenticate: { method in
                        Task { await store.authenticateAgent(method: method) }
                    },
                    onLogout: { Task { await store.logoutAgent() } }
                )
            }

            Section {
                if store.isLoading && store.providers.isEmpty && store.agentAuthMethods.isEmpty {
                    ProgressView(L10n.string("providers.loading"))
                } else if store.providers.isEmpty && store.agentAuthMethods.isEmpty {
                    Text(L10n.string("providers.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedProviders) { provider in
                        ProviderSettingsRow(
                            provider: provider,
                            onAuthenticate: { method in
                                Task {
                                    await store.beginAuthentication(provider: provider, method: method)
                                }
                            },
                            onDisconnect: { disconnectCandidate = provider }
                        )
                    }
                }
            } footer: {
                Text(L10n.string("providers.subtitle"))
            }
        }
        .formStyle(.grouped)
        .task { await store.start() }
        .sheet(isPresented: flowIsPresented) {
            ProviderAuthenticationView(store: store)
        }
        .alert(item: $disconnectCandidate) { provider in
            Alert(
                title: Text(L10n.format("providers.disconnect_title", provider.name)),
                message: Text(L10n.string("providers.disconnect_message")),
                primaryButton: .destructive(Text(L10n.string("common.disconnect"))) {
                    Task { await store.logout(provider: provider) }
                },
                secondaryButton: .cancel(Text(L10n.string("common.cancel")))
            )
        }
    }

    private var flowIsPresented: Binding<Bool> {
        Binding(
            get: { store.flow != nil },
            set: { isPresented in
                if !isPresented { store.clearFlow() }
            }
        )
    }
}

private struct AgentAuthenticationSection: View {
    let methods: [AgentHostACPAuthMethod]
    let activeMethodID: String?
    let isLoggingOut: Bool
    let onAuthenticate: (AgentHostACPAuthMethod) -> Void
    let onLogout: () -> Void

    var body: some View {
        Section {
            ForEach(methods) { method in
                LabeledContent(method.name) {
                    HStack {
                        if activeMethodID == method.id {
                            ProgressView().controlSize(.small)
                        }
                        Button(L10n.string("providers.agent_auth.sign_in")) { onAuthenticate(method) }
                            .disabled(activeMethodID != nil || isLoggingOut)
                    }
                }
            }
            HStack {
                Spacer()
                Button(L10n.string("providers.agent_auth.logout"), action: onLogout)
                    .disabled(activeMethodID != nil || isLoggingOut)
            }
        } header: {
            Text(L10n.string("providers.agent_auth.title"))
        } footer: {
            Text(L10n.string("providers.agent_auth.subtitle"))
        }
    }
}

private struct ProviderSettingsRow: View {
    let provider: AgentHostProvider
    let onAuthenticate: (AgentHostAuthMethod) -> Void
    let onDisconnect: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                providerDetails
                Spacer(minLength: 12)
                providerAction
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                providerDetails
                HStack {
                    Spacer()
                    providerAction
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var providerDetails: some View {
        HStack(alignment: .top, spacing: 12) {
            providerIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name)
                    .font(.headline)
                Text(provider.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Label(statusText, systemImage: provider.status.configured ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if provider.authenticationState == .credentialsSaved {
                    Text(L10n.string("providers.status.not_verified"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.format("providers.models_supported", provider.models.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var providerAction: some View {
        if !provider.methods.isEmpty {
            authenticationControl
        } else if provider.status.canDisconnect {
            Button(L10n.string("common.disconnect"), role: .destructive, action: onDisconnect)
        } else {
            Text(L10n.string(provider.status.configured
                ? "providers.external_configuration"
                : "providers.requires_environment"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(L10n.string("providers.external_help"))
        }
    }

    private var providerIcon: some View {
        Group {
            if let assetName = ProviderIconCatalog.assetName(for: provider.id) {
                Image(assetName)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(String(provider.name.prefix(1)).uppercased())
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var authenticationControl: some View {
        if provider.status.configured {
            Menu {
                authenticationMethodButtons
                if provider.status.canDisconnect {
                    Divider()
                    Button(L10n.string("common.disconnect"), role: .destructive, action: onDisconnect)
                }
            } label: {
                Text(L10n.string("providers.manage"))
            }

        } else if provider.methods.count == 1, let method = provider.methods.first {
            Button(method.loginLabel ?? method.name) {
                onAuthenticate(method.type)
            }
            .buttonStyle(.bordered)
        } else {
            Menu {
                authenticationMethodButtons
            } label: {
                Text(L10n.string("auth.method.choose"))
            }

        }
    }

    @ViewBuilder
    private var authenticationMethodButtons: some View {
        ForEach(provider.methods) { method in
            Button {
                onAuthenticate(method.type)
            } label: {
                Label(
                    method.loginLabel ?? method.name,
                    systemImage: method.type == .oauth ? "safari" : "key"
                )
            }
        }
    }

    private var statusText: String {
        switch provider.authenticationState {
        case .notConfigured:
            return L10n.string("providers.status.not_connected")
        case .signedIn:
            return L10n.string("providers.status.signed_in")
        case .credentialsSaved:
            return L10n.string("providers.status.credentials_saved")
        case .externalCredentials:
            if let label = provider.status.label { return label }
            switch provider.status.source {
            case .runtime: return L10n.string("providers.status.runtime")
            case .environment: return L10n.string("providers.status.environment")
            case .fallback: return L10n.string("providers.status.fallback")
            case .modelsJSONKey, .modelsJSONCommand: return "models.json"
            case .stored, nil: return L10n.string("providers.status.configured")
            }
        }
    }

    private var statusColor: Color {
        switch provider.authenticationState {
        case .signedIn: return .green
        case .credentialsSaved: return Color.accentColor
        case .externalCredentials: return .secondary
        case .notConfigured: return Color.secondary.opacity(0.45)
        }
    }
}

private struct ProviderAuthenticationView: View {
    @ObservedObject var store: ProviderAuthStore
    @State private var responseValue = ""
    @State private var openedExternalURLs: Set<String> = []
    @State private var copiedDeviceCode: String?
    @State private var externalActionError: String?
    @State private var showsGitHubEnterprise = false
    @State private var deviceCodeReceivedAt = Date()
    @FocusState private var inputFocused: Bool

    private var flow: ProviderAuthFlowState? { store.flow }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: flow?.method == .oauth ? "person.badge.key" : "key")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(flow?.providerName ?? L10n.string("auth.title"))
                        .font(.title2)
                    Text(flow?.method == .oauth
                        ? L10n.string("auth.oauth")
                        : L10n.string("auth.api_key"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                if let flow {
                    authenticationContent(flow)
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
                .padding(16)
        }
        .frame(width: 520, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(flow?.phase.isTerminal == false)
        .onAppear {
            openAuthorizationURLIfNeeded()
            openDeviceVerificationURLIfNeeded()
        }
        .onChange(of: flow?.authorizationURL) { _ in openAuthorizationURLIfNeeded() }
        .onChange(of: flow?.deviceCode?.verificationURI) { _ in openDeviceVerificationURLIfNeeded() }
        .onChange(of: flow?.deviceCode?.userCode) { _ in
            copiedDeviceCode = nil
            deviceCodeReceivedAt = Date()
        }
        .onChange(of: flow?.prompt?.promptId) { _ in
            responseValue = ""
            showsGitHubEnterprise = false
            inputFocused = flow?.prompt?.type != .select
        }
    }

    @ViewBuilder
    private func authenticationContent(_ flow: ProviderAuthFlowState) -> some View {
        if !flow.phase.isTerminal, let url = flow.authorizationURL {
            instructionCard(icon: "safari", title: L10n.string("auth.browser.title")) {
                Text(L10n.string("auth.browser.help"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                if flow.authorizationInstructions != nil {
                    Text(L10n.string("auth.browser.manual_help"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Text(url)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button(L10n.string("auth.browser.open")) { open(url) }
                    .buttonStyle(.bordered)
            }
        }

        if !flow.phase.isTerminal, let code = flow.deviceCode {
            instructionCard(icon: "number.square", title: L10n.string("auth.device.title")) {
                Text(L10n.string("auth.device.help"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(code.userCode)
                    .font(.system(size: 23, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(code.verificationURI)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
                    .textSelection(.enabled)
                deviceCodeExpiry(code)
                HStack {
                    Button {
                        copy(code.userCode)
                        copiedDeviceCode = code.userCode
                    } label: {
                        Label(
                            L10n.string(copiedDeviceCode == code.userCode
                                ? "auth.device.copied"
                                : "auth.device.copy"),
                            systemImage: copiedDeviceCode == code.userCode
                                ? "checkmark"
                                : "doc.on.doc"
                        )
                    }
                    Button(L10n.string("auth.device.open")) { open(code.verificationURI) }
                }
                .buttonStyle(.bordered)
            }
        }

        if flow.method == .apiKey, !flow.phase.isTerminal {
            instructionCard(icon: "key", title: L10n.string("auth.credentials.title")) {
                Text(L10n.string("auth.credentials.help"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                if let helpURL = ProviderAuthenticationGuide.credentialHelpURL(for: flow.providerId) {
                    Button(L10n.string("auth.credentials.open_help")) {
                        open(helpURL.absoluteString)
                    }
                    .buttonStyle(.bordered)
                }
                Label(L10n.string("auth.credentials.storage"), systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !flow.phase.isTerminal, let externalActionError {
            statusCard(icon: "exclamationmark.triangle.fill", color: .orange, text: externalActionError)
        }

        ForEach(Array(flow.information.enumerated()), id: \.offset) { _, message in
            Label(
                ProviderAuthenticationPresentation.informationText(
                    message,
                    providerID: flow.providerId
                ),
                systemImage: "info.circle"
            )
                .font(.body)
                .foregroundStyle(.secondary)
        }

        ForEach(flow.links) { link in
            Button(link.label ?? link.url) { open(link.url) }
                .buttonStyle(.link)
        }

        if let prompt = flow.prompt {
            promptView(prompt)
        } else if let progress = flow.progressMessage, !flow.phase.isTerminal {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(ProviderAuthenticationPresentation.progressText(progress))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        } else if !flow.phase.isTerminal {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(flow.phase == .cancelling
                    ? L10n.string("auth.cancelling")
                    : L10n.string("auth.waiting"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }

        terminalView(flow)
    }

    @ViewBuilder
    private func promptView(_ prompt: AgentHostAuthPromptPayload) -> some View {
        let promptTitle = ProviderAuthenticationPresentation.promptTitle(
            providerName: flow?.providerName ?? prompt.providerId,
            prompt: prompt
        )
        VStack(alignment: .leading, spacing: 10) {
            if isGitHubCopilotHostPrompt(prompt) {
                githubCopilotHostPrompt(prompt)
            } else {
                Text(promptTitle)
                    .font(.body)

                if prompt.type == .select {
                    ForEach(prompt.options ?? []) { option in
                        Button {
                            submit(option.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ProviderAuthenticationPresentation.optionTitle(
                                        id: option.id,
                                        fallback: option.label
                                    ))
                                    if let description = option.description {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        }
                        .buttonStyle(.bordered)
                        .disabled(flow?.isSubmitting == true)
                    }
                } else {
                    HStack(spacing: 8) {
                        Group {
                            if prompt.type == .secret {
                                SecureField(
                                    ProviderAuthenticationPresentation.inputPlaceholder(prompt: prompt),
                                    text: $responseValue
                                )
                            } else {
                                TextField(
                                    ProviderAuthenticationPresentation.inputPlaceholder(prompt: prompt),
                                    text: $responseValue
                                )
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .focused($inputFocused)
                        .accessibilityLabel(promptTitle)
                        .onSubmit { submitInput(prompt: prompt) }

                        if isCredentialsFilePrompt(prompt) {
                            Button(L10n.string("auth.choose_file")) {
                                chooseCredentialsFile()
                            }
                            .buttonStyle(.bordered)
                        }

                        Button {
                            submitInput(prompt: prompt)
                        } label: {
                            if flow?.isSubmitting == true {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(L10n.string("common.continue"))
                            }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                (responseValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && prompt.allowsEmpty != true)
                                    || flow?.isSubmitting == true
                            )
                    }
                }
            }

            if let responseError = flow?.responseErrorMessage {
                Label(responseError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(responseError)
            }
        }

    }

    @ViewBuilder
    private func githubCopilotHostPrompt(_ prompt: AgentHostAuthPromptPayload) -> some View {
        Text(L10n.string("auth.github.host.title"))
            .font(.headline)
        Text(L10n.string("auth.github.host.help"))
            .font(.body)
            .foregroundStyle(.secondary)

        Button {
            submit("")
        } label: {
            Label(L10n.string("auth.github.host.github_com"), systemImage: "globe")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(flow?.isSubmitting == true)

        DisclosureGroup(
            L10n.string("auth.github.host.enterprise"),
            isExpanded: $showsGitHubEnterprise
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("auth.github.host.enterprise_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.string("auth.github.host.enterprise_label"))
                    .font(.body)
                HStack(spacing: 8) {
                    TextField(
                        L10n.string("auth.github.host.enterprise_placeholder"),
                        text: $responseValue
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .accessibilityLabel(L10n.string("auth.github.host.enterprise_label"))
                    .onSubmit { submitInput(prompt: prompt) }

                    Button(L10n.string("auth.github.host.enterprise_continue")) {
                        submitInput(prompt: prompt)
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        responseValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || flow?.isSubmitting == true
                    )
                }
            }
            .padding(.top, 8)
        }
        .font(.body)
    }

    @ViewBuilder
    private func terminalView(_ flow: ProviderAuthFlowState) -> some View {
        switch flow.phase {
        case .succeeded:
            statusCard(
                icon: "checkmark.circle.fill",
                color: .green,
                text: flow.method == .oauth
                    ? L10n.string("auth.success")
                    : L10n.string("auth.credentials_saved")
            )
        case .cancelled:
            statusCard(icon: "xmark.circle", color: .secondary, text: L10n.string("auth.cancelled"))
        case .failed:
            let fallback = flow.errorMessage ?? L10n.string("auth.failed")
            statusCard(
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                text: ProviderAuthenticationPresentation.errorMessage(
                    code: flow.errorCode,
                    fallback: fallback
                )
            )
        case .starting, .waitingForProvider, .waitingForUser, .cancelling:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if flow?.phase == .failed {
                Button(L10n.string("auth.retry")) { retryAuthentication() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(L10n.string("common.done")) { store.clearFlow() }
            } else if flow?.phase.isTerminal == true {
                Button(L10n.string("common.done")) { store.clearFlow() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.string("common.cancel")) {
                    Task { await store.cancelAuthentication() }
                }
                .disabled(flow?.phase == .cancelling)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func instructionCard<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            Label(title, systemImage: icon)
        }
    }

    private func statusCard(icon: String, color: Color, text: String) -> some View {
        Label {
            Text(text)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
    }

    private func submitInput(prompt: AgentHostAuthPromptPayload) {
        let value = responseValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty || prompt.allowsEmpty == true else { return }
        submit(value)
    }

    private func submit(_ value: String) {
        Task {
            if await store.respond(value: value) {
                responseValue = ""
            }
        }
    }

    private func isGitHubCopilotHostPrompt(_ prompt: AgentHostAuthPromptPayload) -> Bool {
        flow?.providerId == "github-copilot" && prompt.allowsEmpty == true
    }

    private func openAuthorizationURLIfNeeded() {
        guard let url = flow?.authorizationURL,
              openedExternalURLs.insert(url).inserted else { return }
        open(url)
    }

    private func openDeviceVerificationURLIfNeeded() {
        guard let url = flow?.deviceCode?.verificationURI,
              openedExternalURLs.insert(url).inserted else { return }
        open(url)
    }

    private func open(_ value: String) {
        guard let url = ProviderAuthenticationGuide.webURL(from: value) else {
            externalActionError = L10n.string("auth.browser.open_failed")
            return
        }
        externalActionError = NSWorkspace.shared.open(url)
            ? nil
            : L10n.string("auth.browser.open_failed")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @ViewBuilder
    private func deviceCodeExpiry(_ code: ProviderAuthDeviceCode) -> some View {
        if let expiresInSeconds = code.expiresInSeconds {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(deviceCodeReceivedAt))
                let remaining = max(0, expiresInSeconds - elapsed)
                Text(remaining == 0
                    ? L10n.string("auth.device.expired")
                    : L10n.format("auth.device.expires_seconds", remaining))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isCredentialsFilePrompt(_ prompt: AgentHostAuthPromptPayload) -> Bool {
        prompt.providerId == "google-vertex"
            && prompt.message.localizedCaseInsensitiveContains("file path")
    }

    private func chooseCredentialsFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK {
            responseValue = panel.url?.path ?? responseValue
            inputFocused = true
        }
    }

    private func retryAuthentication() {
        guard let flow,
              let provider = store.providers.first(where: { $0.id == flow.providerId }) else { return }
        responseValue = ""
        openedExternalURLs.removeAll()
        copiedDeviceCode = nil
        externalActionError = nil
        Task {
            await store.beginAuthentication(provider: provider, method: flow.method)
        }
    }
}
