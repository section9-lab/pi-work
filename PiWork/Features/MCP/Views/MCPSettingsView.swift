import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct MCPSettingsView: View {
    @ObservedObject var store: MCPStore
    @State private var editor: MCPEditorTarget?
    @State private var importing = false
    @State private var removing: MCPServer?
    @State private var redirectURL = ""
    @State private var search = ""

    private var filteredServers: [MCPServer] {
        store.servers.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MCPMetrics.pagePadding) {
                header
                if !store.isSupported { message(L10n.string("mcp.unsupported")) }
                if let error = store.errorMessage {
                    MCPCard {
                        VStack(alignment: .leading, spacing: MCPMetrics.fieldSpacing) {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                            Button(L10n.string("common.retry")) { Task { await store.load() } }
                        }
                    }
                }
                ForEach(store.configurationErrors, id: \.self) { error in message(error) }
                if let auth = store.authentication { authentication(auth) }
                if store.isLoading && store.servers.isEmpty {
                    ProgressView(L10n.string("mcp.loading")).frame(maxWidth: .infinity).padding(.vertical, MCPMetrics.pagePadding)
                } else if store.servers.isEmpty && store.isSupported {
                    emptyState
                } else {
                    MCPInput(label: L10n.string("mcp.search"), placeholder: L10n.string("mcp.search"), text: $search)
                        .accessibilityIdentifier("mcp-search")
                    VStack(spacing: MCPMetrics.spacing) {
                        if filteredServers.isEmpty { message(L10n.string("mcp.no_results")) }
                        ForEach(filteredServers) { server in
                            MCPServerCard(server: server, store: store,
                                          onEdit: { editor = MCPEditorTarget(server: server) },
                                          onRemove: { removing = server })
                        }
                    }
                }
                Text(L10n.string("mcp.footer")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MCPMetrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editor) { target in MCPEditorView(store: store, server: target.server) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let json = try String(contentsOf: url, encoding: .utf8)
                Task { _ = await store.importConfiguration(json) }
            } catch { store.errorMessage = error.localizedDescription }
        }
        .confirmationDialog(L10n.string("mcp.remove_confirm"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            if let server = removing {
                Button(L10n.string("mcp.remove"), role: .destructive) {
                    Task { await store.action("remove", server: server) }; removing = nil
                }
            }
            Button(L10n.string("common.cancel"), role: .cancel) { removing = nil }
        }
        .task {
            await store.load()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                await store.load(silent: true)
            }
        }
        .onReceive(store.$authentication.removeDuplicates()) { _ in
            if let url = store.takeAuthorizationURL() { NSWorkspace.shared.open(url) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MCPMetrics.spacing) {
            HStack(spacing: MCPMetrics.fieldSpacing) {
                Text(L10n.string("mcp.title")).font(.system(.title2, weight: .semibold))
                Spacer()
                Button { Task { await store.load(recheck: true) } } label: { MCPGlyph(name: "RefreshCw") }
                    .buttonStyle(.borderless).help(L10n.string("mcp.refresh"))
                    .accessibilityLabel(L10n.string("mcp.refresh"))
                Menu {
                    Button(L10n.string("mcp.import")) { importing = true }
                } label: { MCPGlyph(name: "Ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize().accessibilityLabel(L10n.string("mcp.more"))
                Button { editor = MCPEditorTarget(server: nil) } label: {
                    MCPActionLabel(title: L10n.string("mcp.create"), icon: "Plus")
                }
                .buttonStyle(MCPPrimaryButtonStyle()).accessibilityIdentifier("mcp-add")
            }
            .disabled(store.isWorking || !store.isSupported)
            Text(L10n.string("mcp.subtitle")).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        MCPCard {
            VStack(spacing: MCPMetrics.spacing) {
                MCPGlyph(name: "Plug", size: 28).foregroundStyle(.secondary)
                Text(L10n.string("mcp.empty_title")).font(.headline)
                Text(L10n.string("mcp.empty")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L10n.string("mcp.add")) { editor = MCPEditorTarget(server: nil) }
                    .buttonStyle(MCPPrimaryButtonStyle()).disabled(store.isWorking)
            }.frame(maxWidth: .infinity).padding(.vertical, MCPMetrics.pagePadding)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func authentication(_ auth: MCPAuthentication) -> some View {
        MCPCard {
            VStack(alignment: .leading, spacing: MCPMetrics.spacing) {
                Text("\(L10n.string("mcp.authentication")) · \(auth.name)").font(.headline)
                Text(L10n.string("mcp.auth.\(auth.state)")).foregroundStyle(.secondary)
                if let error = auth.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if auth.state == "authorizing", let server = store.servers.first(where: { $0.name == auth.name }) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button(L10n.string("mcp.open_browser")) {
                            if let value = auth.url, let url = MCPStore.webURL(value) { NSWorkspace.shared.open(url) }
                        }.disabled(auth.url == nil)
                        Spacer()
                        Button(L10n.string("common.cancel")) { Task { await store.action("cancelLogin", server: server) } }
                    }
                    DisclosureGroup(L10n.string("mcp.manual_callback")) {
                        MCPInput(label: L10n.string("mcp.manual_callback"),
                                 placeholder: "http://127.0.0.1:…/callback", text: $redirectURL)
                        Button(L10n.string("mcp.complete_login")) {
                            Task { await store.action("completeLogin", server: server, redirectURL: redirectURL); redirectURL = "" }
                        }.disabled(redirectURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isWorking)
                    }
                }
            }
        }
    }
}

private struct MCPEditorTarget: Identifiable {
    let id = UUID()
    let server: MCPServer?
}

private struct MCPServerCard: View {
    let server: MCPServer
    @ObservedObject var store: MCPStore
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var expanded = false

    private var status: String { server.enabled ? L10n.string("mcp.status.\(server.status)") : L10n.string("mcp.disabled") }
    private var statusColor: Color {
        guard server.enabled else { return .secondary }
        switch server.status {
        case "connected": return .green
        case "failed", "needs-auth": return .orange
        default: return .secondary
        }
    }
    private var endpoint: String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(server.configurationJSON.utf8)) as? [String: Any] else {
            return server.transport == "stdio" ? "STDIO" : "Streamable HTTP"
        }
        if let url = json["url"] as? String, let parts = URLComponents(string: url) {
            return (parts.host ?? "") + parts.path
        }
        return (json["command"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "STDIO"
    }

    var body: some View {
        MCPCard {
            VStack(alignment: .leading, spacing: MCPMetrics.spacing) {
                HStack(spacing: MCPMetrics.spacing) {
                    MCPGlyph(name: server.transport == "stdio" ? "Terminal" : "Globe", size: 20)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius))
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: onEdit) { Text(server.name).font(.system(.body, weight: .semibold)).lineLimit(1) }
                            .buttonStyle(.plain).help(L10n.string("mcp.edit"))
                            .accessibilityLabel("\(L10n.string("mcp.edit")): \(server.name)")
                        Text(endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: MCPMetrics.fieldSpacing)
                    Toggle(L10n.string("mcp.enabled"), isOn: Binding(
                        get: { server.enabled },
                        set: { enabled in Task { await store.action(enabled ? "enable" : "disable", server: server) } }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("\(server.name): \(L10n.string("mcp.enabled"))")
                    Menu {
                        Button(L10n.string("mcp.edit"), action: onEdit)
                        Button(L10n.string("mcp.connect")) { Task { await store.action("check", server: server) } }
                            .disabled(!server.enabled || server.status == "connecting")
                        if server.canLogin {
                            Button(L10n.string(server.signedIn ? "mcp.logout" : "mcp.login")) {
                                Task { await store.action(server.signedIn ? "logout" : "login", server: server) }
                            }.disabled(!server.enabled || store.authentication?.state == "authorizing")
                        }
                        Divider()
                        Button(L10n.string("mcp.remove"), role: .destructive, action: onRemove)
                    } label: { MCPGlyph(name: "Ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("\(L10n.string("mcp.more")): \(server.name)")
                }
                HStack(spacing: MCPMetrics.fieldSpacing) {
                    if server.enabled && server.status == "connecting" { ProgressView().controlSize(.mini) }
                    else { Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true) }
                    Text(status).foregroundStyle(statusColor)
                    Text("·").foregroundStyle(.tertiary)
                    Text(server.transport == "stdio" ? "STDIO" : "HTTP").foregroundStyle(.secondary)
                    Spacer()
                    if !server.tools.isEmpty {
                        Button { expanded.toggle() } label: {
                            HStack(spacing: 4) {
                                Text(L10n.format("mcp.tools", server.tools.count))
                                MCPGlyph(name: "ChevronDown", size: 12).rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(server.name): \(L10n.format("mcp.tools", server.tools.count))")
                    }
                }.font(.caption)
                if let error = server.error, server.enabled {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if expanded {
                    Divider()
                    ForEach(server.tools) { tool in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.name).font(.system(.caption, design: .monospaced))
                            if !tool.description.isEmpty {
                                Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .disabled(store.isWorking)
        }
    }
}
