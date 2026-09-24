import SwiftUI
import AppKit

struct ExtensionsCatalogView: View {
    @ObservedObject var store: ExtensionsCatalogStore
    @ObservedObject var installedStore: InstalledExtensionsStore
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var selectedCategory: PiExtensionCategory = .all
    @State private var isInstalledExtensionsPresented = false

    private var request: ExtensionsCatalogRequest {
        ExtensionsCatalogRequest(query: query)
    }

    private var isRequestPending: Bool {
        store.activeRequest != request || store.isLoading
    }

    private var displayedItems: [PiPackageItem] {
        guard store.activeRequest == request else { return [] }
        return ExtensionsCatalogFilter(
            query: request.query,
            category: selectedCategory
        ).apply(to: store.items)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 24)

                searchField
                    .padding(.bottom, 16)

                categoryFilters
                    .padding(.bottom, 32)

                if let errorMessage = store.errorMessage, !displayedItems.isEmpty {
                    warningNotice(errorMessage)
                        .padding(.bottom, 20)
                }

                content
            }
            .frame(maxWidth: 1_220, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .overlayPreferenceValue(CatalogInstalledManagerAnchorKey.self) { anchor in
            GeometryReader { proxy in
                InWindowFloatingPanel(
                    isPresented: $isInstalledExtensionsPresented,
                    layout: BoundedFloatingPanelLayout(
                        idealWidth: 420,
                        idealMaximumHeight: 500,
                        inset: 16
                    ),
                    anchorFrame: anchor.map { proxy[$0] }
                ) {
                    InstalledExtensionsPanel(store: installedStore)
                }
            }
        }
        .task(id: request) { await updateCatalog(for: request) }
        .task { await installedStore.load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("extensions.title"))
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.5)

                Text(L10n.string("extensions.subtitle"))
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    InstalledExtensionsButton(
                        store: installedStore,
                        isPresented: $isInstalledExtensionsPresented
                    )

                    Button {
                        Task { await store.refresh(request) }
                    } label: {
                        HStack(spacing: 7) {
                            if store.isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            Text(store.isRefreshing
                                ? L10n.string("extensions.updating")
                                : L10n.string("extensions.refresh"))
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                    }
                    .buttonStyle(
                        RoundedInteractionButtonStyle(
                            cornerRadius: 10,
                            baseFill: AppPalette.translucentSurface
                        )
                    )
                    .disabled(store.isLoading || store.isRefreshing)
                    .help(L10n.string("extensions.refresh_help"))
                    .accessibilityLabel(L10n.string("extensions.refresh_accessibility"))
                }

                if let lastUpdated = store.lastUpdated {
                    Text(L10n.format("extensions.updated_at", formattedTime(lastUpdated)))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.42))
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.42))

            TextField(L10n.string("extensions.search_placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .accessibilityLabel(L10n.string("extensions.search_accessibility"))

            if isRequestPending && !request.query.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.string("extensions.searching"))
            }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primary.opacity(0.34))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(L10n.string("extensions.clear_search"))
                .accessibilityLabel(L10n.string("extensions.clear_search"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .containerShape(Capsule())
        .background(
            Capsule()
                .fill(AppPalette.translucentSurface)
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private var categoryFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PiExtensionCategory.allCases, id: \.self) { category in
                    ExtensionsCategoryButton(
                        category: category,
                        isSelected: selectedCategory == category
                    ) {
                        withAnimation(.easeOut(duration: 0.16)) {
                            selectedCategory = category
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isRequestPending && displayedItems.isEmpty {
            loadingGrid
        } else if displayedItems.isEmpty, let errorMessage = store.errorMessage {
            loadingFailure(errorMessage)
        } else if displayedItems.isEmpty {
            emptyResult
        } else {
            catalogGrid
        }
    }

    private var catalogGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: selectedCategory.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .frame(width: 20)

                Text(request.query.isEmpty
                    ? catalogTitle
                    : L10n.string("extensions.search_results"))
                    .font(.system(size: 18, weight: .semibold))

                Text("\(displayedItems.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.45))

                Spacer(minLength: 0)

                Text(L10n.string("extensions.source"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.42))
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(displayedItems) { item in
                    ExtensionsCatalogCard(
                        item: item,
                        installedStore: installedStore
                    )
                }
            }

            Text(L10n.format("extensions.visible_limit", displayedItems.count))
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.46))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private var catalogTitle: String {
        selectedCategory == .all
            ? L10n.string("extensions.popular")
            : selectedCategory.title
    }

    private var loadingGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(request.query.isEmpty
                    ? L10n.string("extensions.loading")
                    : L10n.string("extensions.searching"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.56))
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<6, id: \.self) { _ in
                    ExtensionsCatalogSkeletonCard()
                }
            }
        }
    }

    private func loadingFailure(_ message: String) -> some View {
        ExtensionsCatalogStateView(
            icon: "wifi.exclamationmark",
            title: request.query.isEmpty
                ? L10n.string("extensions.load_failed")
                : L10n.string("extensions.search_failed"),
            message: message,
            actionTitle: L10n.string("extensions.reload")
        ) {
            Task { await store.refresh(request) }
        }
    }

    private var emptyResult: some View {
        ExtensionsCatalogStateView(
            icon: "magnifyingglass",
            title: L10n.string("extensions.no_matches"),
            message: L10n.string("extensions.no_matches_message"),
            actionTitle: L10n.string("extensions.clear_filters")
        ) {
            query = ""
            selectedCategory = .all
        }
    }

    private func warningNotice(_ message: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.orange.opacity(0.9))

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("extensions.update_failed_cache"))
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(L10n.string("common.retry")) {
                Task { await store.refresh(request) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.72))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            adaptiveRoundedShape(cornerRadius: 12)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func updateCatalog(for request: ExtensionsCatalogRequest) async {
        if !request.query.isEmpty {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
        }
        await store.load(request)
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct InstalledExtensionsButton: View {
    @ObservedObject var store: InstalledExtensionsStore
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
            if isPresented {
                Task { await store.load(force: true) }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: 34, height: 34)

                if !store.packages.isEmpty {
                    Text(store.packages.count > 99 ? "99+" : "\(store.packages.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.primary.opacity(0.82)))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(
            RoundedInteractionButtonStyle(
                cornerRadius: 10,
                isSelected: isPresented,
                baseFill: AppPalette.translucentSurface
            )
        )
        .anchorPreference(
            key: CatalogInstalledManagerAnchorKey.self,
            value: .bounds
        ) { $0 }
        .help(L10n.string("extensions.installed.open_help"))
        .accessibilityLabel(L10n.string("extensions.installed.open_accessibility"))
        .accessibilityValue(L10n.format(
            "extensions.installed.count_accessibility",
            store.packages.count
        ))
    }
}

private struct InstalledExtensionsPanel: View {
    @ObservedObject var store: InstalledExtensionsStore
    @State private var pendingRemoval: AgentHostInstalledExtensionPackage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("extensions.installed.title"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L10n.format("extensions.installed.count", store.packages.count))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.46))
                }

                Spacer(minLength: 8)

                Button {
                    Task { await store.load(force: true) }
                } label: {
                    if store.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.isLoading)
                .help(L10n.string("extensions.installed.refresh"))
                .accessibilityLabel(L10n.string("extensions.installed.refresh"))
            }
            .padding(16)

            Divider()
                .opacity(0.55)

            if let errorMessage = store.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.62))
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.07))
            }

            if store.isLoading && store.packages.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("extensions.installed.loading"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.52))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.packages.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.36))
                    Text(L10n.string("extensions.installed.empty"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(L10n.string("extensions.installed.empty_message"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.packages) { package in
                            InstalledExtensionRow(
                                package: package,
                                isWorking: store.isWorking(on: package),
                                onSetEnabled: { enabled in
                                    Task {
                                        await store.setEnabled(package, enabled: enabled)
                                    }
                                },
                                onRemove: { pendingRemoval = package }
                            )

                            if package.id != store.packages.last?.id {
                                Divider()
                                    .padding(.leading, 48)
                                    .opacity(0.45)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
                .opacity(0.55)

            Label(
                L10n.string("extensions.installed.session_note"),
                systemImage: "info.circle"
            )
                .font(.system(size: 10))
                .foregroundStyle(Color.primary.opacity(0.44))
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $pendingRemoval) { package in
            Alert(
                title: Text(L10n.string("extensions.installed.remove_title")),
                message: Text(L10n.format(
                    "extensions.installed.remove_message",
                    package.displayName
                )),
                primaryButton: .destructive(
                    Text(L10n.string("extensions.installed.remove"))
                ) {
                    Task { await store.remove(package) }
                },
                secondaryButton: .cancel(Text(L10n.string("common.cancel")))
            )
        }
    }
}

private struct InstalledExtensionRow: View {
    let package: AgentHostInstalledExtensionPackage
    let isWorking: Bool
    let onSetEnabled: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.62))
                .frame(width: 30, height: 30)
                .background(
                    adaptiveRoundedShape(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(package.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .help(package.source)

                HStack(spacing: 6) {
                    Circle()
                        .fill(package.enabled ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)

                    Text(package.enabled
                        ? L10n.string("extensions.installed.enabled")
                        : L10n.string("extensions.installed.disabled"))

                    Text("·")

                    Text(package.scope == .user
                        ? L10n.string("extensions.installed.user_scope")
                        : L10n.string("extensions.installed.project_scope"))

                    if package.filtered && package.enabled {
                        Text("·")
                        Text(L10n.string("extensions.installed.filtered"))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.primary.opacity(0.46))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !package.isRequiredPiWebAccess {
                Toggle(
                    L10n.string("extensions.installed.enabled"),
                    isOn: Binding(
                        get: { package.enabled },
                        set: onSetEnabled
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isWorking)
                .help(package.enabled
                    ? L10n.string("extensions.installed.disable_help")
                    : L10n.string("extensions.installed.enable_help"))
            }

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else {
                HStack(spacing: 3) {
                    if let installedPath = package.installedPath {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: installedPath)
                            ])
                        } label: {
                            Image(systemName: "folder")
                                .frame(width: 26, height: 26)
                        }
                        .help(L10n.string("extensions.installed.reveal"))
                        .accessibilityLabel(L10n.string("extensions.installed.reveal"))
                    }

                    if !package.isRequiredPiWebAccess {
                        Button(action: onRemove) {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.red.opacity(0.82))
                                .frame(width: 26, height: 26)
                        }
                        .help(L10n.string("extensions.installed.remove"))
                        .accessibilityLabel(L10n.string("extensions.installed.remove"))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.58))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private extension AgentHostInstalledExtensionPackage {
    var isRequiredPiWebAccess: Bool {
        source == "npm:pi-web-access"
    }

    var displayName: String {
        for prefix in ["npm:", "git:"] where source.hasPrefix(prefix) {
            return String(source.dropFirst(prefix.count))
        }
        return source
    }

}

private struct ExtensionsCategoryButton: View {
    let category: PiExtensionCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(category.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? selectedForeground : Color.primary.opacity(0.68))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.primary.opacity(0.88) : AppPalette.translucentSurface)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.primary.opacity(0.11), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedForeground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

private struct ExtensionsCatalogCard: View {
    let item: PiPackageItem
    @ObservedObject var installedStore: InstalledExtensionsStore
    @State private var isHovering = false

    private var isInstalled: Bool {
        installedStore.isInstalled(source: item.packageSource)
    }

    private var isInstalling: Bool {
        installedStore.isWorking(source: item.packageSource)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: openPackage) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.9))
                            .lineLimit(2)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(isHovering ? 0.68 : 0.30))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.string("extensions.open_hint"))

                Spacer(minLength: 0)

                installControl
            }

            Text(item.summary.isEmpty
                ? L10n.string("extensions.no_description")
                : item.summary)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.54))
                .lineSpacing(3)
                .lineLimit(3, reservesSpace: true)
                .truncationMode(.tail)
                .padding(.top, 10)

            if let errorMessage = installedStore.installationError(for: item.packageSource) {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.top, 8)
            }

            Spacer(minLength: 18)

            HStack(spacing: 8) {
                Label(item.extensionCategory.title, systemImage: item.extensionCategory.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.52))

                Text(item.author)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.46))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Label(
                    L10n.format("extensions.downloads_per_month", compactDownloadCount),
                    systemImage: "arrow.down.to.line"
                )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.48))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .containerShape(
            RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous)
        )
        .background(
            adaptiveRoundedShape(cornerRadius: AppCornerRadius.card)
                .fill(AppPalette.translucentSurface)
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: AppCornerRadius.card)
                .stroke(Color.primary.opacity(isHovering ? 0.17 : 0.10), lineWidth: 1)
        )
        .shadow(
            color: isHovering ? AppPalette.subtleShadow : Color.clear,
            radius: 7,
            y: 3
        )
        .offset(y: isHovering ? -1 : 0)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .accessibilityLabel(L10n.format(
            "extensions.download_accessibility",
            item.name,
            compactDownloadCount
        ))
    }

    @ViewBuilder
    private var installControl: some View {
        if isInstalled {
            Label(L10n.string("extensions.installed_label"), systemImage: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.58))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                )
                .accessibilityLabel(L10n.string("extensions.installed_label"))
        } else {
            Button {
                Task {
                    await installedStore.install(source: item.packageSource)
                }
            } label: {
                HStack(spacing: 6) {
                    if isInstalling {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(isInstalling
                        ? L10n.string("extensions.installing")
                        : L10n.string("extensions.install"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(Color.primary.opacity(0.88)))
            }
            .buttonStyle(.plain)
            .disabled(isInstalling)
            .help(L10n.string("extensions.install_help"))
            .accessibilityLabel(L10n.string("extensions.install_help"))
        }
    }

    private var compactDownloadCount: String {
        switch item.monthlyDownloads {
        case 1_000_000...:
            return String(format: "%.1fM", Double(item.monthlyDownloads) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(item.monthlyDownloads) / 1_000)
        default:
            return "\(item.monthlyDownloads)"
        }
    }

    private func openPackage() {
        guard let url = item.pageURL else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct ExtensionsCatalogSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.10))
                .frame(width: 150, height: 16)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.07))
                .frame(maxWidth: .infinity)
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 190, height: 12)
            Spacer(minLength: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 92, height: 12)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(
            adaptiveRoundedShape(cornerRadius: AppCornerRadius.card)
                .fill(AppPalette.translucentSurface)
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: AppCornerRadius.card)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

private struct ExtensionsCatalogStateView: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.42))
                .frame(height: 30)

            Text(title)
                .font(.system(size: 17, weight: .semibold))

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.52))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button(actionTitle, action: action)
                .buttonStyle(
                    RoundedInteractionButtonStyle(
                        cornerRadius: 10,
                        baseFill: AppPalette.translucentSurface
                    )
                )
                .padding(.horizontal, 12)
                .frame(height: 34)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }
}
