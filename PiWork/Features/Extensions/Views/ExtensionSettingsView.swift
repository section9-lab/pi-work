import SwiftUI

struct ExtensionSettingsView: View {
    @ObservedObject var store: InstalledExtensionsStore

    var body: some View {
        Form {
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .textSelection(.enabled)
                    Button(L10n.string("common.retry")) {
                        Task { await reload(force: true) }
                    }
                }
            }

            Section {
                if (store.isLoading || store.isLoadingSettings) && store.packages.isEmpty {
                    ProgressView(L10n.string("settings.extensions.loading"))
                } else if store.packages.isEmpty {
                    Label(L10n.string("settings.extensions.empty"), systemImage: "puzzlepiece.extension")
                } else {
                    Text(L10n.string("settings.extensions.subtitle"))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(store.packages) { package in
                if let settings = store.settings(for: package) {
                    ExtensionSettingsCard(package: package, settings: settings, store: store)
                        .id(settings.formIdentity)
                } else if !store.isLoadingSettings {
                    ExtensionSettingsUnavailableCard(package: package, store: store)
                }
            }

            if !store.packages.isEmpty {
                Section {
                    Text(L10n.string("settings.extensions.changes_apply"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Button {
                Task { await reload(force: true) }
            } label: {
                Label(L10n.string("settings.extensions.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading || store.isLoadingSettings)
            .help(L10n.string("settings.extensions.refresh"))
        }
        .task { await store.load() }
        .task(id: store.packages.map(\.id)) {
            guard !store.packages.isEmpty else { return }
            await store.loadSettings(force: true)
        }
    }

    private func reload(force: Bool) async {
        await store.load(force: force)
        await store.loadSettings(force: force)
    }
}

private struct ExtensionSettingsCard: View {
    let package: AgentHostInstalledExtensionPackage
    let settings: AgentHostExtensionSettings
    @ObservedObject var store: InstalledExtensionsStore
    @State private var isExpanded = false
    @State private var draft: [String: String]
    @State private var removedPaths: Set<String> = []

    init(
        package: AgentHostInstalledExtensionPackage,
        settings: AgentHostExtensionSettings,
        store: InstalledExtensionsStore
    ) {
        self.package = package
        self.settings = settings
        self.store = store
        _draft = State(initialValue: Self.makeDraft(from: settings.fields))
    }

    var body: some View {
        Section {
            LabeledContent {
                ExtensionPackageUpdateButton(package: package, store: store)
            } label: {
                ExtensionPackageSummary(package: package, store: store)
            }

            if !package.isRequiredExtension {
                Toggle(
                    L10n.string("extensions.installed.enabled"),
                    isOn: Binding(
                        get: { package.enabled },
                        set: { enabled in
                            Task { await store.setEnabled(package, enabled: enabled) }
                        }
                    )
                )
                .toggleStyle(.switch)
                .accessibilityLabel("\(package.settingsDisplayName): \(L10n.string("extensions.installed.enabled"))")
                .disabled(store.isWorking(on: package))
            }

            if settings.configurable, !settings.fields.isEmpty {
                DisclosureGroup(L10n.string("settings.extensions.expand"), isExpanded: $isExpanded) {
                    settingsForm
                }
            } else {
                Text(L10n.string("settings.extensions.no_options"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var settingsForm: some View {
        Group {
            ForEach(basicFields) { field in
                fieldEditor(field)
            }

            if !advancedFields.isEmpty {
                DisclosureGroup(L10n.string("settings.extensions.advanced")) {
                    ForEach(advancedFields) { field in
                        fieldEditor(field)
                    }
                }
            }

            LabeledContent {
                HStack {
                    if store.isSavingSettings(for: settings) {
                        ProgressView().controlSize(.small)
                    }
                    Button(L10n.string(store.isSavingSettings(for: settings)
                        ? "settings.extensions.saving"
                        : "settings.extensions.save")) { save() }
                        .disabled(changes.isEmpty || store.isSavingSettings(for: settings))
                }
            } label: {
                Text(L10n.string("settings.extensions.schema_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(store.isSavingSettings(for: settings))
    }

    private func fieldEditor(_ field: AgentHostExtensionSettingField) -> some View {
        ExtensionSettingFieldEditor(
            field: field,
            value: draftBinding(for: field),
            hasStoredValue: field.hasValue && !removedPaths.contains(field.path),
            canReset: field.hasValue && !field.required && !field.readOnly && !removedPaths.contains(field.path),
            onReset: { reset(field) }
        )
    }

    private var basicFields: [AgentHostExtensionSettingField] {
        settings.fields.filter { !$0.advanced }
    }

    private var advancedFields: [AgentHostExtensionSettingField] {
        settings.fields.filter(\.advanced)
    }

    private var changes: [AgentHostExtensionSettingChange] {
        settings.fields.compactMap { field in
            guard !field.readOnly else { return nil }
            if removedPaths.contains(field.path) {
                return AgentHostExtensionSettingChange(removing: field.path)
            }
            let draftValue = draft[field.path] ?? Self.initialValue(for: field)
            if field.kind == .secure {
                return draftValue.isEmpty
                    ? nil
                    : AgentHostExtensionSettingChange(path: field.path, value: draftValue)
            }
            guard draftValue != Self.initialValue(for: field) else { return nil }
            return AgentHostExtensionSettingChange(path: field.path, value: draftValue)
        }
    }

    private func draftBinding(for field: AgentHostExtensionSettingField) -> Binding<String> {
        Binding(
            get: { draft[field.path] ?? Self.initialValue(for: field) },
            set: {
                removedPaths.remove(field.path)
                draft[field.path] = $0
            }
        )
    }

    private func reset(_ field: AgentHostExtensionSettingField) {
        draft[field.path] = Self.resetValue(for: field)
        removedPaths.insert(field.path)
    }

    private func save() {
        let pendingChanges = changes
        Task {
            if await store.updateSettings(settings, changes: pendingChanges) {
                removedPaths.removeAll()
                for field in settings.fields where field.kind == .secure {
                    draft[field.path] = ""
                }
            }
        }
    }

    private static func makeDraft(
        from fields: [AgentHostExtensionSettingField]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.path, initialValue(for: $0)) })
    }

    private static func initialValue(for field: AgentHostExtensionSettingField) -> String {
        if field.kind == .secure { return "" }
        return field.value ?? field.defaultValue ?? (field.kind == .boolean ? "false" : "")
    }

    private static func resetValue(for field: AgentHostExtensionSettingField) -> String {
        if field.kind == .secure { return "" }
        return field.defaultValue ?? (field.kind == .boolean ? "false" : "")
    }
}

private struct ExtensionSettingsUnavailableCard: View {
    let package: AgentHostInstalledExtensionPackage
    @ObservedObject var store: InstalledExtensionsStore

    var body: some View {
        Section {
            LabeledContent {
                ExtensionPackageUpdateButton(package: package, store: store)
            } label: {
                ExtensionPackageSummary(package: package, store: store)
            }
            Text(L10n.string("settings.extensions.no_options"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExtensionPackageSummary: View {
    let package: AgentHostInstalledExtensionPackage
    @ObservedObject var store: InstalledExtensionsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(package.settingsDisplayName)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .help(package.source)
            HStack(spacing: 6) {
                if let version = package.version {
                    Text(verbatim: "v\(version)")
                    Text("·")
                }
                Text(package.scope == .user
                    ? L10n.string("extensions.installed.user_scope")
                    : L10n.string("extensions.installed.project_scope"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let message = store.updateMessages[package.id] {
                Label(message, systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExtensionPackageUpdateButton: View {
    let package: AgentHostInstalledExtensionPackage
    @ObservedObject var store: InstalledExtensionsStore

    var body: some View {
        if package.canUpdate {
            Button {
                Task { await store.update(package) }
            } label: {
                HStack(spacing: 5) {
                    if store.isWorking(on: package) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(L10n.string("settings.extensions.update"))
                }
            }
            .controlSize(.small)
            .disabled(store.isWorking(on: package) || store.activeSettingsIDs.contains(package.id))
            .help(L10n.string("settings.extensions.update_help"))
            .accessibilityLabel("\(package.settingsDisplayName): \(L10n.string("settings.extensions.update"))")
            .accessibilityIdentifier("extension-package-update-\(package.id)")
        }
    }
}

private struct ExtensionSettingFieldEditor: View {
    let field: AgentHostExtensionSettingField
    @Binding var value: String
    let hasStoredValue: Bool
    let canReset: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let group = field.group, !group.isEmpty {
                Text(group)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if field.kind == .boolean {
                Toggle(isOn: booleanBinding) {
                    fieldLabel
                }
                .toggleStyle(.switch)
                .accessibilityLabel(field.title)
            } else if field.kind == .choice, let options = field.options, !options.isEmpty {
                Picker(selection: $value) {
                    ForEach(options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                } label: {
                    fieldLabel
                }
                .pickerStyle(.menu)
                .accessibilityLabel(field.title)
            } else {
                fieldLabel
                editor
                    .accessibilityLabel(field.title)
            }

            if canReset {
                HStack {
                    Spacer()
                    Button(
                        L10n.string(field.kind == .secure
                            ? "settings.extensions.clear_secret"
                            : "settings.extensions.reset"),
                        action: onReset
                    )
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .disabled(field.readOnly)
    }

    private var fieldLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.title + (field.required ? " *" : ""))
            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch field.kind {
        case .secure:
            SecureField(
                L10n.string(hasStoredValue
                    ? "settings.extensions.secure_configured"
                    : "settings.extensions.secure_placeholder"),
                text: $value
            )
            .textFieldStyle(.roundedBorder)
        case .json:
            TextEditor(text: $value)
                .font(.body.monospaced())
                .frame(minHeight: 100, maxHeight: 160)
        case .integer, .number, .text, .choice:
            TextField(field.title, text: $value)
                .textFieldStyle(.roundedBorder)
        case .boolean:
            EmptyView()
        }
    }

    private var booleanBinding: Binding<Bool> {
        Binding(
            get: { value == "true" },
            set: { value = $0 ? "true" : "false" }
        )
    }
}

private extension AgentHostInstalledExtensionPackage {
    var canUpdate: Bool {
        source.hasPrefix("npm:")
            || source.hasPrefix("git:")
            || source.hasPrefix("https://")
            || source.hasPrefix("ssh://")
    }

    var settingsDisplayName: String {
        for prefix in ["npm:", "git:"] where source.hasPrefix(prefix) {
            return String(source.dropFirst(prefix.count))
        }
        return source
    }

    var isRequiredExtension: Bool {
        source == "npm:pi-web-access"
    }
}

private extension AgentHostExtensionSettings {
    var formIdentity: String {
        let values = fields.map { field in
            "\(field.path)=\(field.value ?? ""):\(field.hasValue)"
        }.joined(separator: "|")
        return "\(id):\(values)"
    }
}
