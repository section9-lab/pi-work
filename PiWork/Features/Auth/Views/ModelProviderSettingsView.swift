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
    @State private var selection = SettingsDestination.general

    var body: some View {
        ZStack {
            AppBackgroundGradient()
                .ignoresSafeArea(.container, edges: .top)

            HStack(spacing: 8) {
                SettingsSidebar(selection: $selection, language: languageStore.language)
                    .padding(10)

                Group {
                    switch selection {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(globalInstructionsStore)
            }
        }
        .frame(minWidth: 656, idealWidth: 720, minHeight: 560, idealHeight: 620)
        .background(SettingsWindowChrome())
        .task {
            await agentSettingsStore.start()
            globalInstructionsStore.load()
        }
    }
}

private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SettingsWindowChromeView)?.configureWindow()
    }
}

private final class SettingsWindowChromeView: NSView {
    private var observers: [NSObjectProtocol] = []
    private var didApplyInitialWidth = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        guard let window else { return }
        observers = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didUpdateNotification,
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.configureWindow()
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.configureWindow()
            self?.applyInitialWidth()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func configureWindow() {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
    }

    private func applyInitialWidth() {
        guard !didApplyInitialWidth, let window else { return }
        didApplyInitialWidth = true

        var frame = window.frame
        frame.origin.x += (frame.width - 720) / 2
        frame.size.width = 720
        window.setFrame(frame, display: true)
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
    @Binding var selection: SettingsDestination
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("settings.title", language: language))
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 24)

            settingsButton(.general)
                .padding(.bottom, 14)

            Text(L10n.string("settings.sidebar.section"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 7)

            ForEach([
                SettingsDestination.agent,
                .extensions,
                .personalPreferences,
                .modelsAndAuthentication,
                .experiments,
            ]) { destination in
                settingsButton(destination)
            }

            Spacer()

            Text(L10n.string("settings.sidebar.isolated", language: language))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
        .frame(width: 190)
        .background(
            adaptiveRoundedShape(cornerRadius: 18)
                .fill(AppPalette.sidebarSurface)
                .shadow(color: AppPalette.subtleShadow, radius: 6, y: 2)
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: 18)
                .stroke(AppPalette.panelBorder, lineWidth: 1)
        )
    }

    private func settingsButton(_ destination: SettingsDestination) -> some View {
        Button {
            selection = destination
        } label: {
            Label(destination.title(language: language), systemImage: destination.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 38)
        }
        .buttonStyle(RoundedInteractionButtonStyle(
            cornerRadius: 10,
            isSelected: selection == destination
        ))
    }
}

private struct GlobalAgentInstructionsSettingsView: View {
    @EnvironmentObject private var store: GlobalAgentInstructionsStore

    var body: some View {
        VStack(spacing: 0) {
            pageHeader

            if let errorMessage = store.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            VStack(alignment: .leading, spacing: 12) {
                editor
                Label(
                    L10n.string("settings.personal_preferences.changes_apply"),
                    systemImage: "info.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("settings.personal_preferences.title"))
                .font(.system(size: 20, weight: .semibold))
            Text(L10n.string("settings.personal_preferences.subtitle"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("AGENTS.md")
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.fileURL.path.replacingOccurrences(
                        of: NSHomeDirectory(),
                        with: "~"
                    ))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                }

                if store.didSave {
                    Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .help(L10n.string("settings.personal_preferences.saved"))
                }

                Spacer(minLength: 6)

                Button {
                    store.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.string("settings.personal_preferences.reload"))
                .accessibilityLabel(L10n.string("settings.personal_preferences.reload"))
                .disabled(store.isLoading || store.isSaving || store.hasUnsavedChanges)

                Button(L10n.string("settings.personal_preferences.revert")) {
                    store.revert()
                }
                .disabled(!store.hasUnsavedChanges || store.isSaving)

                Button(L10n.string("settings.personal_preferences.save")) {
                    store.save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.hasUnsavedChanges || store.isSaving)
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(height: 52)

            Divider()
                .padding(.leading, 14)

            AlignedPlaceholderTextEditor(
                text: $store.draft,
                placeholder: L10n.string("settings.personal_preferences.placeholder")
            )
            .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .settingsCard()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button(L10n.string("common.retry")) { store.load() }
        }
        .padding(12)
        .background(
            adaptiveRoundedShape(cornerRadius: 11)
                .fill(Color.orange.opacity(0.10))
        )
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
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay

        let textView = PlaceholderTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.placeholder = placeholder
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("settings.experiments.title"))
                    .font(.system(size: 20, weight: .semibold))
                Text(L10n.string("settings.experiments.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            VStack(spacing: 16) {
                AgentSettingsRow(
                    title: L10n.string("settings.experiments.computer_use.title"),
                    description: L10n.string("settings.experiments.computer_use.description")
                ) {
                    HStack(spacing: 10) {
                        Text(L10n.string("settings.experiments.coming_soon"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: .constant(false))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(true)
                    }
                }
                .settingsCard()

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var languageStore: LanguageStore
    @ObservedObject var piCodingAgentUpdateController: AppUpdateController
    @ObservedObject var updateController: AppUpdateController

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("settings.general.title"))
                    .font(.system(size: 20, weight: .semibold))
                Text(L10n.string("settings.general.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 16) {
                    AgentSettingsRow(
                        title: L10n.string("settings.general.language.title"),
                        description: L10n.string("settings.general.language.description")
                    ) {
                        Picker(
                            L10n.string("settings.general.language.title"),
                            selection: $languageStore.language
                        ) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 170, alignment: .trailing)
                    }
                    .settingsCard()

                    PiCodingAgentUpdateSettingsRow(controller: piCodingAgentUpdateController)
                        .settingsCard()

                    AppUpdateSettingsRow(controller: updateController)
                        .settingsCard()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
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

private extension View {
    func settingsCard() -> some View {
        background(
            adaptiveRoundedShape(cornerRadius: 15)
                .fill(AppPalette.translucentSurface)
                .shadow(color: AppPalette.subtleShadow, radius: 4, y: 1)
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: 15)
                .stroke(AppPalette.panelBorder, lineWidth: 1)
        )
    }
}

private struct AgentGeneralSettingsView: View {
    @ObservedObject var store: AgentSettingsStore

    var body: some View {
        VStack(spacing: 0) {
            pageHeader

            if let errorMessage = store.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }

            if store.isLoading && store.settings == nil {
                ProgressView(L10n.string("settings.agent.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.settings != nil {
                settingsContent
            } else {
                unavailableState
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("settings.agent.title"))
                    .font(.system(size: 20, weight: .semibold))
                Text(L10n.string("settings.agent.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .help(L10n.string("settings.agent.saving"))
            }

            Button {
                Task { await store.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 9))
            .disabled(store.isLoading || store.isSaving)
            .help(L10n.string("settings.agent.reload"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                AgentSettingsSection(
                    title: L10n.string("settings.agent.session_defaults.title"),
                    subtitle: L10n.string("settings.agent.session_defaults.subtitle")
                ) {
                    AgentSettingsRow(
                        title: L10n.string("settings.agent.default_model.title"),
                        description: L10n.string("settings.agent.default_model.description")
                    ) {
                        Picker(L10n.string("settings.agent.default_model.title"), selection: modelSelection) {
                            Text(L10n.string("settings.agent.default_model.select")).tag("")
                            ForEach(sortedModels) { model in
                                Text("\(model.name) · \(model.provider)")
                                    .tag(modelKey(model))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 250)
                    }

                    Divider().padding(.leading, 16)

                    AgentSettingsRow(
                        title: L10n.string("settings.agent.thinking.title"),
                        description: L10n.string("settings.agent.thinking.description")
                    ) {
                        Picker(L10n.string("settings.agent.thinking.title"), selection: thinkingSelection) {
                            ForEach(AgentHostThinkingLevel.allCases) { level in
                                Text(level.settingsTitle).tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                }

                AgentSettingsSection(
                    title: L10n.string("settings.agent.runtime.title"),
                    subtitle: L10n.string("settings.agent.runtime.subtitle")
                ) {
                    AgentSettingsRow(
                        title: L10n.string("settings.agent.compaction.title"),
                        description: L10n.string("settings.agent.compaction.description")
                    ) {
                        Toggle("", isOn: compactionSelection)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider().padding(.leading, 16)

                    AgentSettingsRow(
                        title: L10n.string("settings.agent.retry.title"),
                        description: L10n.string("settings.agent.retry.description")
                    ) {
                        Toggle("", isOn: retrySelection)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                AgentSettingsSection(
                    title: L10n.string("settings.agent.connection.title"),
                    subtitle: L10n.string("settings.agent.connection.subtitle")
                ) {
                    AgentSettingsRow(
                        title: L10n.string("settings.agent.transport.title"),
                        description: L10n.string("settings.agent.transport.description")
                    ) {
                        Picker(L10n.string("settings.agent.transport.title"), selection: transportSelection) {
                            ForEach(AgentHostTransport.allCases) { transport in
                                Text(transport.settingsTitle).tag(transport)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }
                }

                Label(
                    L10n.string("settings.agent.changes_apply"),
                    systemImage: "info.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .disabled(store.isSaving)
    }

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(L10n.string("settings.agent.unavailable"))
                .font(.headline)
            Button(L10n.string("common.retry")) { Task { await store.reload() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button(L10n.string("common.retry")) { Task { await store.reload() } }
        }
        .padding(12)
        .background(
            adaptiveRoundedShape(cornerRadius: 11)
                .fill(Color.orange.opacity(0.10))
        )
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

private struct AgentSettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 7)

            content
        }
        .background(
            adaptiveRoundedShape(cornerRadius: 15)
                .fill(AppPalette.translucentSurface)
                .shadow(color: AppPalette.subtleShadow, radius: 4, y: 1)
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: 15)
                .stroke(AppPalette.panelBorder, lineWidth: 1)
        )
    }
}

private struct AgentSettingsRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder let control: Control

    init(
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
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
    @State private var searchText = ""
    @State private var disconnectCandidate: AgentHostProvider?

    private var visibleProviders: [AgentHostProvider] {
        store.providers
            .filter { provider in
                searchText.isEmpty
                    || provider.name.localizedCaseInsensitiveContains(searchText)
                    || provider.id.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { lhs, rhs in
                if lhs.status.configured != rhs.status.configured {
                    return lhs.status.configured
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            if let errorMessage = store.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }

            if store.isLoading && store.providers.isEmpty && store.agentAuthMethods.isEmpty {
                ProgressView(L10n.string("providers.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleProviders.isEmpty && store.agentAuthMethods.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !store.agentAuthMethods.isEmpty {
                            AgentAuthenticationSection(
                                methods: store.agentAuthMethods,
                                activeMethodID: store.activeAgentAuthMethodID,
                                isLoggingOut: store.isLoggingOutAgent,
                                onAuthenticate: { method in
                                    Task { await store.authenticateAgent(method: method) }
                                },
                                onLogout: {
                                    Task { await store.logoutAgent() }
                                }
                            )
                        }
                        ForEach(visibleProviders) { provider in
                            ProviderSettingsRow(
                                provider: provider,
                                onAuthenticate: { method in
                                    Task {
                                        await store.beginAuthentication(
                                            provider: provider,
                                            method: method
                                        )
                                    }
                                },
                                onDisconnect: {
                                    disconnectCandidate = provider
                                }
                            )
                        }
                    }
                    .padding(24)
                }
            }
        }
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

    private var settingsHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("providers.title"))
                    .font(.system(size: 20, weight: .semibold))
                Text(L10n.string("providers.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            TextField(L10n.string("providers.search"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)

            Button {
                Task { await store.reloadProviders() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoading)
            .help(L10n.string("providers.refresh_help"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L10n.string("providers.no_match"))
                .font(.headline)
            Text(L10n.string("providers.no_match_hint"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button(L10n.string("common.retry")) {
                Task { await store.reloadProviders() }
            }
        }
        .padding(12)
        .background(
            adaptiveRoundedShape(cornerRadius: 10)
                .fill(Color.orange.opacity(0.09))
        )
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("providers.agent_auth.title"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L10n.string("providers.agent_auth.subtitle"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 12)
                Button(L10n.string("providers.agent_auth.logout"), action: onLogout)
                    .disabled(activeMethodID != nil || isLoggingOut)
            }

            ForEach(methods) { method in
                HStack {
                    Text(method.name)
                        .font(.system(size: 13))
                    Spacer(minLength: 12)
                    Button(L10n.string("providers.agent_auth.sign_in")) {
                        onAuthenticate(method)
                    }
                    .disabled(activeMethodID != nil || isLoggingOut)
                    .overlay {
                        if activeMethodID == method.id {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.035))
        .adaptiveCornerRadius(12)
    }
}

private struct ProviderSettingsRow: View {
    let provider: AgentHostProvider
    let onAuthenticate: (AgentHostAuthMethod) -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            providerIcon

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(provider.name)
                        .font(.system(size: 14, weight: .medium))
                    Text(provider.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                    if provider.authenticationState == .credentialsSaved {
                        Text("·")
                        Text(L10n.string("providers.status.not_verified"))
                    }
                    Text("·")
                    Text(L10n.format(
                        "providers.models_supported",
                        provider.models.total
                    ))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if !provider.methods.isEmpty {
                authenticationControl
            } else if provider.status.canDisconnect {
                Button(L10n.string("common.disconnect"), role: .destructive, action: onDisconnect)
                    .buttonStyle(.bordered)
            } else if provider.status.configured {
                Text(L10n.string("providers.external_configuration"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L10n.string("providers.external_help"))
            } else {
                Text(L10n.string("providers.requires_environment"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            adaptiveRoundedShape(cornerRadius: 12)
                .fill(AppPalette.translucentSurface)
                .shadow(color: AppPalette.subtleShadow, radius: 4, y: 1)
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: 12)
                .stroke(AppPalette.panelBorder, lineWidth: 1)
        )
    }

    private var providerIcon: some View {
        ZStack {
            adaptiveRoundedShape(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.10))

            if let assetName = ProviderIconCatalog.assetName(for: provider.id) {
                Image(assetName)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .padding(7)
            } else {
                Text(String(provider.name.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 38, height: 38)
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
            .menuStyle(.borderlessButton)
            .fixedSize()
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
            .menuStyle(.borderlessButton)
            .fixedSize()
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
                        .font(.system(size: 17, weight: .semibold))
                    Text(flow?.method == .oauth
                        ? L10n.string("auth.oauth")
                        : L10n.string("auth.api_key"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let flow {
                        authenticationContent(flow)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()
            footer
                .padding(16)
        }
        .frame(width: 520, height: 500)
        .background(AppPalette.windowGradient)
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if flow.authorizationInstructions != nil {
                    Text(L10n.string("auth.browser.manual_help"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(url)
                    .font(.system(size: 11, design: .monospaced))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(code.userCode)
                    .font(.system(size: 23, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(code.verificationURI)
                    .font(.system(size: 11, design: .monospaced))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let helpURL = ProviderAuthenticationGuide.credentialHelpURL(for: flow.providerId) {
                    Button(L10n.string("auth.credentials.open_help")) {
                        open(helpURL.absoluteString)
                    }
                    .buttonStyle(.bordered)
                }
                Label(L10n.string("auth.credentials.storage"), systemImage: "lock.shield")
                    .font(.system(size: 11))
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
                .font(.system(size: 12))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if !flow.phase.isTerminal {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(flow.phase == .cancelling
                    ? L10n.string("auth.cancelling")
                    : L10n.string("auth.waiting"))
                    .font(.system(size: 12))
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
                    .font(.system(size: 13, weight: .medium))

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
                                            .font(.system(size: 11))
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
                        .buttonStyle(RoundedInteractionButtonStyle(
                            cornerRadius: 9,
                            baseFill: Color.primary.opacity(0.045)
                        ))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(responseError)
            }
        }
        .padding(14)
        .background(
            adaptiveRoundedShape(cornerRadius: 11)
                .fill(AppPalette.translucentSurface)
        )
    }

    @ViewBuilder
    private func githubCopilotHostPrompt(_ prompt: AgentHostAuthPromptPayload) -> some View {
        Text(L10n.string("auth.github.host.title"))
            .font(.system(size: 13, weight: .semibold))
        Text(L10n.string("auth.github.host.help"))
            .font(.system(size: 12))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(L10n.string("auth.github.host.enterprise_label"))
                    .font(.system(size: 12, weight: .medium))
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
        .font(.system(size: 12, weight: .medium))
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            adaptiveRoundedShape(cornerRadius: 11)
                .fill(AppPalette.translucentSurface)
        )
    }

    private func statusCard(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
            .font(.system(size: 13, weight: .medium))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                adaptiveRoundedShape(cornerRadius: 11)
                    .fill(color.opacity(0.09))
            )
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
                    .font(.system(size: 11))
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
