import SwiftUI
import AppKit

struct SkillsCatalogView: View {
    @ObservedObject var store: SkillsCatalogStore
    @Environment(\.locale) private var locale
    @StateObject private var installedSkillsStore = InstalledSkillsStore()
    @State private var query = ""
    @State private var selectedCategory: SkillsCatalogCategory = .all
    @State private var isInstalledSkillsPresented = false

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearchPending: Bool {
        !normalizedQuery.isEmpty
            && (store.searchQuery != normalizedQuery || store.isSearching)
    }

    private var displayedItems: [SkillsCatalogItem] {
        guard !normalizedQuery.isEmpty else { return store.items }
        guard store.searchQuery == normalizedQuery else { return [] }
        return store.searchResults
    }

    private var filteredItems: [SkillsCatalogItem] {
        SkillsCatalogFilter(query: "", category: selectedCategory).apply(to: displayedItems)
    }

    private var visibleItems: [SkillsCatalogItem] {
        Array(filteredItems.prefix(120))
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

                if let errorMessage = installedSkillsStore.errorMessage {
                    warningNotice(
                        title: L10n.string("skills.install.error.title"),
                        message: errorMessage,
                        actionTitle: L10n.string("skills.install.error.dismiss")
                    ) {
                        installedSkillsStore.clearError()
                    }
                    .padding(.bottom, 20)
                }

                if normalizedQuery.isEmpty,
                   let errorMessage = store.errorMessage,
                   !store.items.isEmpty {
                    warningNotice(
                        title: L10n.string("skills.update_failed_cache"),
                        message: errorMessage,
                        actionTitle: L10n.string("common.retry")
                    ) {
                        Task { await store.refresh() }
                    }
                    .padding(.bottom, 20)
                }

                if !normalizedQuery.isEmpty,
                   !isSearchPending,
                   let errorMessage = store.searchErrorMessage,
                   !filteredItems.isEmpty {
                    warningNotice(
                        title: L10n.string("skills.search_failed_local"),
                        message: errorMessage,
                        actionTitle: L10n.string("common.retry")
                    ) {
                        Task { await store.search(query) }
                    }
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
                    isPresented: $isInstalledSkillsPresented,
                    layout: BoundedFloatingPanelLayout(
                        idealWidth: 460,
                        idealMaximumHeight: 520,
                        inset: 16
                    ),
                    anchorFrame: anchor.map { proxy[$0] }
                ) {
                    InstalledSkillsPanel(store: installedSkillsStore)
                }
            }
        }
        .onAppear { installedSkillsStore.reload() }
        .task { await store.loadIfNeeded() }
        .task(id: query) { await updateSearch() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("skills.title"))
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.5)

                Text(L10n.string("skills.subtitle"))
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    InstalledSkillsButton(
                        store: installedSkillsStore,
                        isPresented: $isInstalledSkillsPresented
                    )

                    Button {
                        Task { await store.refresh() }
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
                                ? L10n.string("skills.updating")
                                : L10n.string("skills.refresh"))
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
                    .disabled(store.isInitialLoading || store.isRefreshing)
                    .help(L10n.string("skills.refresh_help"))
                    .accessibilityLabel(L10n.string("skills.refresh_accessibility"))
                }

                if let lastUpdated = store.lastUpdated {
                    Text(L10n.format("skills.updated_at", formattedTime(lastUpdated)))
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

            TextField(L10n.string("skills.search_placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .accessibilityLabel(L10n.string("skills.search_accessibility"))

            if isSearchPending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.string("skills.searching_accessibility"))
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
                .help(L10n.string("skills.clear_search"))
                .accessibilityLabel(L10n.string("skills.clear_search"))
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
                ForEach(SkillsCatalogCategory.allCases, id: \.self) { category in
                    SkillCategoryButton(
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
        if !normalizedQuery.isEmpty {
            if isSearchPending {
                searchLoading
            } else if filteredItems.isEmpty {
                if let errorMessage = store.searchErrorMessage {
                    searchFailure(errorMessage)
                } else {
                    emptySearchResult
                }
            } else {
                catalogGrid
            }
        } else if store.isInitialLoading && store.items.isEmpty {
            loadingGrid
        } else if store.items.isEmpty {
            loadingFailure
        } else if filteredItems.isEmpty {
            emptySearchResult
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

                Text(
                    normalizedQuery.isEmpty
                        ? (selectedCategory == .all
                            ? L10n.string("skills.popular")
                            : selectedCategory.title)
                        : L10n.string("skills.search_results")
                )
                    .font(.system(size: 18, weight: .semibold))

                Text("\(filteredItems.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.45))

                Spacer(minLength: 0)

                Text(L10n.string("skills.source"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.42))
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(visibleItems) { item in
                    SkillsCatalogCard(
                        item: item,
                        isInstalled: installedSkillsStore.isInstalled(item),
                        isInstalling: installedSkillsStore.installingSkillID == item.id,
                        onInstall: {
                            Task { await installedSkillsStore.install(item) }
                        }
                    )
                        .task(id: item.summary == nil) {
                            guard item.summary == nil else { return }
                            await store.loadSummary(for: item.id)
                        }
                }
            }

            if filteredItems.count > visibleItems.count {
                Text(L10n.format("skills.visible_limit", visibleItems.count))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.46))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }

    private var loadingGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("skills.loading"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.56))
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<6, id: \.self) { _ in
                    SkillsCatalogSkeletonCard()
                }
            }
        }
    }

    private var searchLoading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(L10n.string("skills.searching"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.56))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    private var loadingFailure: some View {
        SkillsCatalogStateView(
            icon: "wifi.exclamationmark",
            title: L10n.string("skills.load_failed"),
            message: store.errorMessage ?? L10n.string("skills.network_retry"),
            actionTitle: L10n.string("skills.reload")
        ) {
            Task { await store.refresh() }
        }
    }

    private var emptySearchResult: some View {
        SkillsCatalogStateView(
            icon: "magnifyingglass",
            title: L10n.string("skills.no_matches"),
            message: L10n.string("skills.no_matches_message"),
            actionTitle: L10n.string("skills.clear_filters")
        ) {
            query = ""
            selectedCategory = .all
        }
    }

    private func searchFailure(_ message: String) -> some View {
        SkillsCatalogStateView(
            icon: "wifi.exclamationmark",
            title: L10n.string("skills.search_failed"),
            message: message,
            actionTitle: L10n.string("skills.search_again")
        ) {
            Task { await store.search(query) }
        }
    }

    private func warningNotice(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.orange.opacity(0.9))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(actionTitle, action: action)
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

    private func updateSearch() async {
        let query = normalizedQuery
        guard !query.isEmpty else {
            store.clearSearch()
            return
        }

        do {
            try await Task.sleep(nanoseconds: 350_000_000)
        } catch {
            return
        }
        await store.search(query)
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct InstalledSkillsButton: View {
    @ObservedObject var store: InstalledSkillsStore
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
            if isPresented { store.reload() }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "tray.full")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .frame(width: 34, height: 34)

                if !store.skills.isEmpty {
                    Text(store.skills.count > 99 ? "99+" : "\(store.skills.count)")
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
        .help(L10n.string("skills.installed.open_help"))
        .accessibilityLabel(L10n.string("skills.installed.open_accessibility"))
        .accessibilityValue(L10n.format(
            "skills.installed.count_accessibility",
            store.skills.count
        ))
    }
}

private struct InstalledSkillsPanel: View {
    @ObservedObject var store: InstalledSkillsStore
    @State private var pendingRemoval: InstalledSkill?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("skills.installed.title"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L10n.format("skills.installed.count", store.skills.count))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.46))
                }

                Spacer(minLength: 8)

                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(L10n.string("skills.installed.refresh"))
                .accessibilityLabel(L10n.string("skills.installed.refresh"))
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
                    Button {
                        store.clearError()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("skills.install.error.dismiss"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.07))
            }

            installedContent

            Divider()
                .opacity(0.55)

            Label(
                L10n.string("skills.installed.session_note"),
                systemImage: "info.circle"
            )
            .font(.system(size: 10))
            .foregroundStyle(Color.primary.opacity(0.44))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppPalette.raisedSurface)
        .alert(item: $pendingRemoval) { skill in
            Alert(
                title: Text(L10n.format("skills.installed.remove_title", skill.name)),
                message: Text(L10n.string("skills.installed.remove_message")),
                primaryButton: .destructive(
                    Text(L10n.string("skills.installed.remove"))
                ) {
                    Task { await store.remove(skill) }
                },
                secondaryButton: .cancel(Text(L10n.string("common.cancel")))
            )
        }
    }

    @ViewBuilder
    private var installedContent: some View {
        if store.skills.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.36))
                Text(L10n.string("skills.installed.empty"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.string("skills.installed.empty_message"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.skills) { skill in
                        InstalledSkillRow(
                            skill: skill,
                            isWorking: store.isWorking(on: skill),
                            onSetEnabled: { enabled in
                                Task { await store.setEnabled(enabled, for: skill) }
                            },
                            onRemove: { pendingRemoval = skill }
                        )

                        if skill.id != store.skills.last?.id {
                            Divider()
                                .padding(.leading, 52)
                                .opacity(0.45)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct InstalledSkillRow: View {
    let skill: InstalledSkill
    let isWorking: Bool
    let onSetEnabled: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.62))
                .frame(width: 30, height: 30)
                .background(
                    adaptiveRoundedShape(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(skill.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Text(skill.description ?? L10n.string("skills.installed.no_description"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(skill.isEnabled ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(skill.isEnabled
                        ? L10n.string("skills.installed.enabled")
                        : L10n.string("skills.installed.disabled"))
                    Text("·")
                    Text(sources.map(\.title).joined(separator: " · "))
                }
                .font(.system(size: 9))
                .foregroundStyle(Color.primary.opacity(0.44))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            Toggle(isOn: Binding(
                get: { skill.isEnabled },
                set: onSetEnabled
            )) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isWorking)
            .help(skill.isEnabled
                ? L10n.string("skills.installed.disable")
                : L10n.string("skills.installed.enable"))
            .accessibilityLabel(skill.isEnabled
                ? L10n.string("skills.installed.disable")
                : L10n.string("skills.installed.enable"))

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else {
                HStack(spacing: 2) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([skill.fileURL])
                    } label: {
                        Image(systemName: "folder")
                            .frame(width: 26, height: 26)
                    }
                    .help(L10n.string("skills.installed.reveal"))
                    .accessibilityLabel(L10n.string("skills.installed.reveal"))

                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .foregroundStyle(Color.red.opacity(0.82))
                            .frame(width: 26, height: 26)
                    }
                    .help(L10n.string("skills.installed.remove"))
                    .accessibilityLabel(L10n.string("skills.installed.remove"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.58))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var sources: [InstalledSkillSource] {
        var seen: Set<InstalledSkillSource> = []
        return skill.installations.compactMap { installation in
            seen.insert(installation.source).inserted ? installation.source : nil
        }
    }
}

private extension InstalledSkillSource {
    var title: String {
        switch self {
        case .piAgent: return L10n.string("skills.installed.source_pi")
        case .sharedAgents: return L10n.string("skills.installed.source_shared")
        }
    }

    var icon: String {
        switch self {
        case .piAgent: return "terminal"
        case .sharedAgents: return "person.2"
        }
    }
}

private struct SkillCategoryButton: View {
    let category: SkillsCatalogCategory
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

private struct SkillsCatalogCard: View {
    let item: SkillsCatalogItem
    let isInstalled: Bool
    let isInstalling: Bool
    let onInstall: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: openSkill) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayName)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .lineLimit(2)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(isHovering ? 0.68 : 0.30))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.string("skills.open_hint"))

                Spacer(minLength: 0)

                downloadControl
            }

            Text(item.summary ?? L10n.string("skills.loading_description"))
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.54))
                .lineSpacing(3)
                .lineLimit(3, reservesSpace: true)
                .truncationMode(.tail)
                .redacted(reason: item.summary == nil ? .placeholder : [])
                .padding(.top, 10)

            Spacer(minLength: 18)

            HStack(spacing: 8) {
                Label(SkillsCatalogCategory.inferred(for: item).title, systemImage: "tag")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.52))

                if item.isOfficial {
                    Label(L10n.string("skills.official"), systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }

                Spacer(minLength: 0)

                Label(compactInstallCount, systemImage: "arrow.down.to.line")
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
            "skills.install_accessibility",
            displayName,
            compactInstallCount
        ))
    }

    @ViewBuilder
    private var downloadControl: some View {
        if isInstalled {
            Label(L10n.string("skills.downloaded"), systemImage: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.58))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                )
                .accessibilityLabel(L10n.string("skills.downloaded"))
        } else {
            Button(action: onInstall) {
                HStack(spacing: 6) {
                    if isInstalling {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(isInstalling
                        ? L10n.string("skills.downloading")
                        : L10n.string("skills.download"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(Color.primary.opacity(0.88)))
            }
            .buttonStyle(.plain)
            .disabled(isInstalling)
            .help(L10n.string("skills.download_help"))
            .accessibilityLabel(L10n.format("skills.download_accessibility", displayName))
        }
    }

    private var displayName: String {
        guard item.name == item.name.lowercased(), item.name.contains("-") else {
            return item.name
        }
        return item.name
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var compactInstallCount: String {
        switch item.installs {
        case 1_000_000...:
            return String(format: "%.1fM", Double(item.installs) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(item.installs) / 1_000)
        default:
            return "\(item.installs)"
        }
    }

    private func openSkill() {
        guard let url = item.pageURL else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SkillsCatalogSkeletonCard: View {
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

private struct SkillsCatalogStateView: View {
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
