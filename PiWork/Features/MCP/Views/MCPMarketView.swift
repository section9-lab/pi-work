import SwiftUI

struct MCPMarketView: View {
    @ObservedObject var store: MCPStore
    @ObservedObject var catalog: MCPMarketCatalogStore
    let onConfigure: (MCPMarketPreset) -> Void
    @State private var search = ""
    @State private var filter: Filter = .all

    private enum Filter: CaseIterable { case all, remote, local }
    private var requestSearch: String {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.count >= 3 ? query : ""
    }
    private var visibleItems: [MCPMarketPreset] {
        catalog.items.filter {
            (requestSearch.isEmpty ? $0.matchesSearch(search) : true)
                && (filter == .all || (filter == .local ? $0.isLocal : $0.isRemote))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("mcp.market.title")).font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 8)
                Link(destination: URL(string: "https://registry.modelcontextprotocol.io")!) {
                    HStack(spacing: 4) {
                        Text("MCP Registry")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await catalog.load(search: requestSearch, refresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless).disabled(catalog.isLoading)
                .help(L10n.string("mcp.refresh"))
                .accessibilityLabel(L10n.string("mcp.refresh"))
            }
            Text(L10n.string("mcp.market.subtitle")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -10)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.string("mcp.market.search"), text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L10n.string("mcp.market.search"))
                    .accessibilityIdentifier("mcp-market-search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel(L10n.string("mcp.market.clear_search"))
                }
                if catalog.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.10)))

            HStack(spacing: 6) {
                filterButton(.all, title: L10n.string("mcp.market.all"))
                filterButton(.remote, title: L10n.string("mcp.market.remote"))
                filterButton(.local, title: L10n.string("mcp.market.local"))
                Spacer(minLength: 0)
                Text(L10n.format("mcp.market.loaded_count", catalog.items.count))
                    .font(.caption).foregroundStyle(.tertiary)
            }

            if catalog.isCached {
                notice(L10n.string("mcp.market.cached"), symbol: "wifi.slash")
            }
            if let error = catalog.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    notice(L10n.string("mcp.market.load_failed"), symbol: "exclamationmark.circle")
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Button(L10n.string("common.retry")) {
                        Task { await catalog.retry() }
                    }.buttonStyle(.borderless)
                }
            }
            if catalog.isLoading && catalog.items.isEmpty {
                ProgressView(L10n.string("mcp.market.loading"))
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else if visibleItems.isEmpty && catalog.errorMessage == nil {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
                    Text(L10n.string("mcp.market.no_results")).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: MCPMetrics.marketCardWidth), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    ForEach(visibleItems) { preset in
                        MCPMarketCard(preset: preset, installed: store.installedServer(for: preset) != nil,
                                      disabled: store.isWorking || !store.isSupported,
                                      onConfigure: { onConfigure(preset) })
                    }
                }
            }
            if catalog.nextCursor != nil {
                HStack {
                    Spacer()
                    Button(L10n.string("mcp.market.load_more")) { Task { await catalog.loadMore() } }
                        .buttonStyle(.bordered).disabled(catalog.isLoading)
                    Spacer()
                }.padding(.top, 4)
            }
            Text(L10n.string("mcp.market.privacy")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: requestSearch) {
            if !requestSearch.isEmpty {
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            }
            await catalog.load(search: requestSearch)
        }
        .accessibilityIdentifier("mcp-market")
    }

    private func filterButton(_ value: Filter, title: String) -> some View {
        Button { filter = value } label: {
            Text(title).font(.system(size: 11, weight: filter == value ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(filter == value ? Color.primary : Color.secondary)
                .background(filter == value ? Color.primary.opacity(0.07) : .clear, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    private func notice(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MCPMarketCard: View {
    let preset: MCPMarketPreset
    let installed: Bool
    let disabled: Bool
    let onConfigure: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MCPBrandIconView(name: preset.name, urls: preset.iconURLs, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(preset.publisher).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let url = MCPStore.webURL(preset.documentationURL) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary).help(L10n.string("mcp.market.documentation"))
                    .accessibilityLabel("\(preset.name): \(L10n.string("mcp.market.documentation"))")
                }
            }
            Text(preset.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(preset.transportLabel).font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
                Spacer(minLength: 0)
                if preset.isInstallable {
                    Button(action: onConfigure) {
                        HStack(spacing: 4) {
                            Image(systemName: installed ? "checkmark" : "plus").font(.system(size: 10, weight: .medium))
                            Text(L10n.string(installed ? "mcp.market.added" : "mcp.market.configure"))
                        }.font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(installed || disabled)
                    .accessibilityIdentifier("mcp-market-add-\(preset.id)")
                } else if let url = MCPStore.webURL(preset.documentationURL) {
                    Link(L10n.string("mcp.market.setup_guide"), destination: url).font(.caption)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).frame(height: 158)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.primary.opacity(isHovered ? 0.18 : 0.09)))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }
}
