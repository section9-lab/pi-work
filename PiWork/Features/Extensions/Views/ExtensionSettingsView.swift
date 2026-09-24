import SwiftUI

struct ExtensionSettingsView: View {
    @ObservedObject var store: InstalledExtensionsStore

    var body: some View {
        VStack(spacing: 0) {
            pageHeader

            if let errorMessage = store.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            content
        }
        .task { await store.load() }
        .task(id: store.packages.map(\.id)) {
            guard !store.packages.isEmpty else { return }
            await store.loadSettings(force: true)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("settings.extensions.title"))
                    .font(.system(size: 20, weight: .semibold))
                Text(L10n.string("settings.extensions.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await reload(force: true) }
            } label: {
                if store.isLoading || store.isLoadingSettings {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(RoundedInteractionButtonStyle(cornerRadius: 9))
            .disabled(store.isLoading || store.isLoadingSettings)
            .help(L10n.string("settings.extensions.refresh"))
            .accessibilityLabel(L10n.string("settings.extensions.refresh"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var content: some View {
        if (store.isLoading || store.isLoadingSettings) && store.packages.isEmpty {
            ProgressView(L10n.string("settings.extensions.loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.packages.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text(L10n.string("settings.extensions.empty"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.packages) { package in
                        if let settings = store.settings(for: package) {
                            ExtensionSettingsCard(
                                package: package,
                                settings: settings,
                                store: store
                            )
                            .id(settings.formIdentity)
                        } else if !store.isLoadingSettings {
                            ExtensionSettingsUnavailableCard(
                                package: package,
                                store: store
                            )
                        }
                    }

                    Label(
                        L10n.string("settings.extensions.changes_apply"),
                        systemImage: "info.circle"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            Button(L10n.string("common.retry")) {
                Task { await reload(force: true) }
            }
        }
        .padding(12)
        .background(
            adaptiveRoundedShape(cornerRadius: 11)
                .fill(Color.orange.opacity(0.10))
        )
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .frame(width: 30, height: 30)
                    .background(
                        adaptiveRoundedShape(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.06))
                    )

                ExtensionPackageSummary(package: package, store: store)

                Spacer(minLength: 8)

                ExtensionPackageUpdateButton(package: package, store: store)

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
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(store.isWorking(on: package))
                }

                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.configurable
                    ? L10n.string("settings.extensions.expand")
                    : L10n.string("settings.extensions.no_options"))
            }
            .padding(14)

            if isExpanded {
                Divider()
                    .padding(.leading, 14)

                if settings.configurable, !settings.fields.isEmpty {
                    settingsForm
                } else {
                    Label(
                        L10n.string("settings.extensions.no_options"),
                        systemImage: "slider.horizontal.3"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
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

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(basicFields.enumerated()), id: \.element.id) { index, field in
                ExtensionSettingFieldEditor(
                    field: field,
                    value: draftBinding(for: field),
                    hasStoredValue: field.hasValue && !removedPaths.contains(field.path),
                    canReset: field.hasValue
                        && !field.required
                        && !field.readOnly
                        && !removedPaths.contains(field.path),
                    onReset: { reset(field) }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                if index < basicFields.count - 1 || !advancedFields.isEmpty {
                    Divider().padding(.leading, 16)
                }
            }

            if !advancedFields.isEmpty {
                DisclosureGroup(L10n.string("settings.extensions.advanced")) {
                    VStack(spacing: 0) {
                        ForEach(Array(advancedFields.enumerated()), id: \.element.id) { index, field in
                            ExtensionSettingFieldEditor(
                                field: field,
                                value: draftBinding(for: field),
                                hasStoredValue: field.hasValue
                                    && !removedPaths.contains(field.path),
                                canReset: field.hasValue
                                    && !field.required
                                    && !field.readOnly
                                    && !removedPaths.contains(field.path),
                                onReset: { reset(field) }
                            )
                            .padding(.vertical, 12)

                            if index < advancedFields.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            Divider().padding(.leading, 16)

            HStack {
                Text(L10n.string("settings.extensions.schema_note"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                if store.isSavingSettings(for: settings) {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(store.isSavingSettings(for: settings)
                    ? L10n.string("settings.extensions.saving")
                    : L10n.string("settings.extensions.save")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(changes.isEmpty || store.isSavingSettings(for: settings))
            }
            .padding(14)
        }
        .disabled(store.isSavingSettings(for: settings))
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
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                ExtensionPackageSummary(package: package, store: store)
                Text(L10n.string("settings.extensions.no_options"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ExtensionPackageUpdateButton(package: package, store: store)
        }
        .padding(14)
        .background(
            adaptiveRoundedShape(cornerRadius: 15)
                .fill(AppPalette.translucentSurface)
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: 15)
                .stroke(AppPalette.panelBorder, lineWidth: 1)
        )
    }
}

private struct ExtensionPackageSummary: View {
    let package: AgentHostInstalledExtensionPackage
    @ObservedObject var store: InstalledExtensionsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(package.settingsDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
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
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let message = store.updateMessages[package.id] {
                Label(message, systemImage: "checkmark")
                    .font(.system(size: 10))
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
        VStack(alignment: .leading, spacing: 7) {
            if let group = field.group, !group.isEmpty {
                Text(group)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.title + (field.required ? " *" : ""))
                    .font(.system(size: 12, weight: .medium))

                Spacer(minLength: 8)

                if canReset {
                    Button(
                        field.kind == .secure
                            ? L10n.string("settings.extensions.clear_secret")
                            : L10n.string("settings.extensions.reset"),
                        action: onReset
                    )
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                if field.kind == .boolean {
                    Toggle("", isOn: booleanBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }

            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if field.kind != .boolean {
                editor
            }
        }
        .disabled(field.readOnly)
    }

    @ViewBuilder
    private var editor: some View {
        switch field.kind {
        case .choice:
            if let options = field.options, !options.isEmpty {
                Picker(field.title, selection: $value) {
                    ForEach(options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(field.title, text: $value)
                    .textFieldStyle(.roundedBorder)
            }
        case .secure:
            SecureField(
                hasStoredValue
                    ? L10n.string("settings.extensions.secure_configured")
                    : L10n.string("settings.extensions.secure_placeholder"),
                text: $value
            )
            .textFieldStyle(.roundedBorder)
        case .integer, .number:
            TextField(field.title, text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180, alignment: .leading)
        case .json:
            TextEditor(text: $value)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 82, maxHeight: 130)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(adaptiveRoundedShape(cornerRadius: 8))
                .overlay(
                    adaptiveRoundedShape(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
        case .text:
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
