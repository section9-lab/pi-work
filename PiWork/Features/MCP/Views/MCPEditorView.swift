import SwiftUI

struct MCPEditorView: View {
    @ObservedObject var store: MCPStore
    let server: MCPServer?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MCPServerDraft
    @State private var allowInChat: Bool
    @State private var readOnlyTools: Set<String>
    @State private var jsonMode = false
    @State private var rawJSON = ""
    @State private var localError: String?
    @State private var didEdit = false
    @State private var permissionsExpanded = false
    @State private var advancedExpanded = false

    init(store: MCPStore, server: MCPServer?) {
        self.store = store
        self.server = server
        _draft = State(initialValue: MCPServerDraft(server: server))
        _allowInChat = State(initialValue: server?.allowInChat ?? false)
        _readOnlyTools = State(initialValue: Set(server?.readOnlyTools ?? []))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: MCPMetrics.pagePadding) {
                    if jsonMode {
                        nameField
                        MCPField(title: L10n.string("mcp.configuration")) {
                            TextEditor(text: $rawJSON)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 260)
                                .padding(MCPMetrics.fieldSpacing)
                                .overlay(RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
                                .accessibilityLabel(L10n.string("mcp.configuration"))
                        }
                        Text(L10n.string("mcp.configuration_note")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        connectionFields
                        DisclosureGroup(isExpanded: $advancedExpanded) {
                            VStack(alignment: .leading, spacing: MCPMetrics.spacing) {
                                if draft.transport == .stdio {
                                    MCPField(title: L10n.string("mcp.cwd"), hint: L10n.string("mcp.cwd_hint")) {
                                        MCPInput(label: L10n.string("mcp.cwd"), placeholder: "/path/to/project", text: $draft.workingDirectory)
                                    }
                                }
                                Text(L10n.string("mcp.advanced_hint")).font(.caption).foregroundStyle(.secondary)
                                Button(L10n.string("mcp.edit_json")) { switchMode() }
                            }.padding(.top, MCPMetrics.spacing)
                        } label: { Text(L10n.string("mcp.advanced")).font(.system(.body, weight: .medium)) }
                    }
                    permissions
                }
                .padding(.horizontal, MCPMetrics.pagePadding)
                .padding(.vertical, MCPMetrics.spacing)
            }
            .disabled(store.isWorking)
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 560)
        .frame(height: min(780, max(500, (NSScreen.main?.visibleFrame.height ?? 860) - 100)))
        .interactiveDismissDisabled(store.isWorking)
        .onChange(of: draft.name) { _ in didEdit = true; localError = nil }
        .onChange(of: draft.commandLine) { _ in didEdit = true; localError = nil }
        .onChange(of: draft.url) { _ in didEdit = true; localError = nil }
        .onChange(of: draft.timeout) { _ in didEdit = true; localError = nil }
        .onChange(of: rawJSON) { _ in localError = nil }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: MCPMetrics.spacing) {
            VStack(alignment: .leading, spacing: MCPMetrics.fieldSpacing) {
                Text(L10n.string(server == nil ? "mcp.editor.add" : "mcp.editor.edit"))
                    .font(.system(.title3, weight: .semibold))
                Text(L10n.string("mcp.editor.subtitle")).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { MCPGlyph(name: "X") }
                .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                .help(L10n.string("common.cancel")).accessibilityLabel(L10n.string("common.cancel"))
                .disabled(store.isWorking)
        }.padding(MCPMetrics.pagePadding)
    }

    private var nameField: some View {
        MCPField(title: L10n.string("mcp.name"), required: true) {
            MCPInput(label: L10n.string("mcp.name"), placeholder: "my-mcp-server", text: $draft.name)
                .disabled(server != nil).accessibilityIdentifier("mcp-server-name")
        }
    }

    @ViewBuilder private var connectionFields: some View {
        MCPField(title: L10n.string("mcp.transport")) {
            Menu {
                ForEach(MCPTransport.allCases) { transport in
                    Button(transport.title) { draft.transport = transport }
                }
            } label: {
                Text(draft.transport.title)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(maxWidth: .infinity, minHeight: MCPMetrics.controlHeight, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(alignment: .trailing) {
                MCPGlyph(name: "ChevronDown").foregroundStyle(.secondary)
                    .padding(.trailing, 12).allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius))
            .accessibilityLabel(L10n.string("mcp.transport"))
            .accessibilityValue(draft.transport.title)
            .accessibilityIdentifier("mcp-transport")
        }
        nameField
        if draft.transport == .stdio {
            MCPField(title: L10n.string("mcp.command"), required: true, hint: L10n.string("mcp.command_hint")) {
                MCPCommandInput(text: $draft.commandLine)
            }
            MCPKeyValueEditor(title: L10n.string("mcp.environment"), entries: $draft.environment)
        } else {
            MCPField(title: L10n.string("mcp.url"), required: true, hint: L10n.string("mcp.url_hint")) {
                MCPInput(label: L10n.string("mcp.url"), placeholder: "https://example.com/mcp", text: $draft.url)
                    .accessibilityIdentifier("mcp-server-url")
            }
            MCPKeyValueEditor(title: "Headers", isHeaders: true, entries: $draft.headers)
        }
        MCPField(title: L10n.string("mcp.timeout"), hint: L10n.string("mcp.timeout_hint")) {
            MCPInput(label: L10n.string("mcp.timeout"), placeholder: "60", text: $draft.timeout)
                .accessibilityIdentifier("mcp-timeout")
        }
    }

    private var permissions: some View {
        DisclosureGroup(isExpanded: $permissionsExpanded) {
            VStack(alignment: .leading, spacing: MCPMetrics.spacing) {
                Toggle(L10n.string("mcp.allow_chat"), isOn: $allowInChat).toggleStyle(.switch)
                Text(L10n.string("mcp.permission_note")).font(.caption).foregroundStyle(.secondary)
                if let server, !server.tools.isEmpty {
                    Text(L10n.string("mcp.allow_read_only")).font(.system(.body, weight: .medium))
                    ForEach(server.tools) { tool in
                        Toggle(isOn: Binding(
                            get: { readOnlyTools.contains(tool.callName) },
                            set: { allowed in
                                if allowed { readOnlyTools.insert(tool.callName) } else { readOnlyTools.remove(tool.callName) }
                            }
                        )) {
                            Text(tool.name).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        .accessibilityLabel("\(tool.name): \(L10n.string("mcp.allow_read_only"))")
                    }
                } else {
                    Text(L10n.string("mcp.connect_for_tools")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, MCPMetrics.spacing)
        } label: {
            Text(L10n.string("mcp.permissions")).font(.system(.body, weight: .medium))
        }
    }

    private var footer: some View {
        VStack(spacing: MCPMetrics.spacing) {
            if let error = localError ?? store.errorMessage ?? (didEdit ? validationError : nil) {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mcp-editor-error")
            }
            Button {
                Task {
                    do {
                        let parameters = try saveParameters()
                        if await store.save(parameters) { dismiss() }
                    } catch { localError = error.localizedDescription }
                }
            } label: {
                HStack {
                    if store.isWorking { ProgressView().controlSize(.small) }
                    Text(L10n.string(server == nil ? "mcp.create" : "mcp.save"))
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(MCPPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            .disabled(validationError != nil || store.isWorking)
            .accessibilityIdentifier("mcp-save")
            if jsonMode {
                Button(L10n.string("mcp.use_form")) { switchMode() }
                    .buttonStyle(.borderless).disabled(store.isWorking)
            }
        }
        .padding(MCPMetrics.pagePadding)
    }

    private var validationError: String? {
        do { _ = try saveParameters(); return nil } catch { return error.localizedDescription }
    }

    private func saveParameters() throws -> MCPSaveParameters {
        var value = draft
        if jsonMode { try value.applyJSON(rawJSON) }
        return MCPSaveParameters(
            name: value.name.trimmingCharacters(in: .whitespacesAndNewlines),
            configurationJSON: try value.configurationJSON(),
            allowInChat: allowInChat, readOnlyTools: readOnlyTools.sorted()
        )
    }

    private func switchMode() {
        do {
            if jsonMode { try draft.applyJSON(rawJSON) }
            else { rawJSON = try draft.configurationJSON(validate: false) }
            jsonMode.toggle()
            localError = nil
        } catch { localError = error.localizedDescription }
    }
}
