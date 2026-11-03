import SwiftUI

struct MCPMarketView: View {
    @ObservedObject var store: MCPStore
    let onConfigure: (MCPMarketPreset) -> Void
    @State private var search = ""
    @State private var addingID: String?
    @State private var addError: (id: String, message: String)?

    private var presets: [MCPMarketPreset] { MCPMarketPreset.all.filter { $0.matchesSearch(search) } }

    var body: some View {
        VStack(alignment: .leading, spacing: MCPMetrics.spacing) {
            VStack(alignment: .leading, spacing: MCPMetrics.fieldSpacing) {
                Text(L10n.string("mcp.market.title")).font(.system(.title3, weight: .semibold))
                Text(L10n.string("mcp.market.subtitle")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MCPInput(label: L10n.string("mcp.market.search"), placeholder: L10n.string("mcp.market.search"), text: $search)
                .accessibilityIdentifier("mcp-market-search")
            if presets.isEmpty {
                Text(L10n.string("mcp.market.no_results")).foregroundStyle(.secondary)
                    .padding(.vertical, MCPMetrics.spacing)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: MCPMetrics.marketCardWidth), spacing: MCPMetrics.spacing)],
                          alignment: .leading, spacing: MCPMetrics.spacing) {
                    ForEach(presets) { preset in
                        marketCard(preset)
                    }
                }
            }
            Text(L10n.string("mcp.market.privacy")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("mcp-market")
    }

    private func marketCard(_ preset: MCPMarketPreset) -> some View {
        let installed = store.installedServer(for: preset) != nil
        return MCPCard {
            VStack(alignment: .leading, spacing: MCPMetrics.spacing) {
                HStack(spacing: MCPMetrics.fieldSpacing) {
                    Image(systemName: preset.symbol)
                        .font(.title3).foregroundStyle(.secondary)
                        .frame(width: MCPMetrics.controlHeight, height: MCPMetrics.controlHeight)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.name).font(.headline).lineLimit(1)
                        Text(preset.publisher).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let url = MCPStore.webURL(preset.documentationURL) {
                        Link(destination: url) { Image(systemName: "info.circle") }
                            .help(L10n.string("mcp.market.documentation"))
                            .accessibilityLabel("\(preset.name): \(L10n.string("mcp.market.documentation"))")
                    }
                }
                Text(preset.summary).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                HStack(spacing: MCPMetrics.fieldSpacing) {
                    Text(L10n.string(preset.isLocal ? "mcp.market.local" : preset.requiresLogin ? "mcp.market.login_required" : "mcp.market.remote"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        if preset.isLocal { onConfigure(preset) }
                        else {
                            addingID = preset.id
                            addError = nil
                            Task {
                                let saved = await store.addMarketPreset(preset)
                                if !saved, let message = store.errorMessage {
                                    addError = (preset.id, message)
                                }
                                addingID = nil
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if addingID == preset.id { ProgressView().controlSize(.mini) }
                            else if installed { Image(systemName: "checkmark") }
                            Text(L10n.string(installed ? "mcp.market.added" : preset.isLocal ? "mcp.market.configure" : preset.requiresLogin ? "mcp.market.connect" : "mcp.create"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(installed || addingID != nil || store.isWorking || store.isLoading || !store.isSupported || store.authentication?.state == "authorizing")
                    .accessibilityIdentifier("mcp-market-add-\(preset.id)")
                    .accessibilityLabel("\(preset.name): \(L10n.string(installed ? "mcp.market.added" : preset.isLocal ? "mcp.market.configure" : preset.requiresLogin ? "mcp.market.connect" : "mcp.create"))")
                }
                if let addError, addError.id == preset.id {
                    Text(addError.message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("mcp-market-error-\(preset.id)")
                }
            }
        }
    }
}
