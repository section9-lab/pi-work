import XCTest
import SwiftUI
@testable import PiWork

final class ExtensionsCatalogTests: XCTestCase {
    func testPackageUpdateControlsLiveInSettingsNotTheCatalog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent(
            "PiWork/Features/Extensions/Views/ExtensionSettingsView.swift"
        ), encoding: .utf8)
        let catalog = try String(contentsOf: root.appendingPathComponent(
            "PiWork/Features/Extensions/Views/ExtensionsCatalogView.swift"
        ), encoding: .utf8)

        XCTAssertTrue(settings.contains("await store.update(package)"))
        XCTAssertTrue(settings.contains("package.version"))
        XCTAssertTrue(settings.contains("extension-package-update-"))
        XCTAssertFalse(catalog.contains("onUpdate"))
    }

    @MainActor
    func testPackageUpdateRefreshesVersionAndClearsSuccessFeedbackOnFailure() async {
        let original = AgentHostInstalledExtensionPackage(
            source: "npm:pi-tools", scope: .user, filtered: false,
            installedPath: nil, enabled: true, version: "1.2.3"
        )
        let updated = AgentHostInstalledExtensionPackage(
            source: original.source, scope: .user, filtered: false,
            installedPath: nil, enabled: true, version: "1.3.0"
        )
        let service = StubInstalledExtensionsService(packages: [original])
        let store = InstalledExtensionsStore(service: service)
        await store.load()
        await service.setUpdateResult(.success([updated]))
        await store.update(original)
        XCTAssertEqual(store.packages.first?.version, "1.3.0")
        XCTAssertNotNil(store.updateMessages[original.id])

        await service.setUpdateResult(.failure(AgentHostClientError.requestFailed(
            code: "invalid_request", message: "Package update failed: registry unavailable"
        )))
        await store.update(updated)
        XCTAssertEqual(store.packages, [updated])
        XCTAssertNil(store.updateMessages[original.id])
        XCTAssertEqual(store.errorMessage, "Package update failed: registry unavailable")
        XCTAssertTrue(store.activePackageIDs.isEmpty)
    }

    @MainActor
    func testPluginSettingsLayoutWithAndWithoutDeclaredSettings() async throws {
        let packages = ["@scope/task-runner", "generic-plugin"].map { name in
            AgentHostInstalledExtensionPackage(
                source: "npm:\(name)", scope: .user, filtered: false,
                installedPath: nil, enabled: true, version: "1.2.3"
            )
        }
        let service = StubInstalledExtensionsService(packages: packages, settings: [
            AgentHostExtensionSettings(source: packages[0].source, scope: .user, configurable: false, fields: [])
        ])
        let store = InstalledExtensionsStore(service: service)
        await store.load()
        await store.loadSettings()
        for scheme in [ColorScheme.light, .dark] {
            let bitmap = try TestViewRenderer.render(
                ExtensionSettingsView(store: store)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme),
                size: CGSize(width: 520, height: 420)
            )
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "plugin-settings-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testPackageUpdateRefreshesPreviouslyLoadedSettings() async {
        let package = AgentHostInstalledExtensionPackage(
            source: "npm:pi-tools", scope: .user, filtered: false,
            installedPath: nil, enabled: true
        )
        let service = StubInstalledExtensionsService(packages: [package])
        let store = InstalledExtensionsStore(service: service)
        await store.load()
        await store.loadSettings()

        await store.update(package)

        let actions = await service.recordedActions()
        XCTAssertEqual(actions, [.list, .listSettings, .update(package), .listSettings])
        XCTAssertFalse(store.isWorking(on: package))
    }

    func testExtensionsCatalogFeatureHasDedicatedModelAndView() {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repositoryRoot
                    .appendingPathComponent("PiWork/Features/Extensions/ExtensionsCatalog.swift")
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repositoryRoot
                    .appendingPathComponent("PiWork/Features/Extensions/Views/ExtensionsCatalogView.swift")
                    .path
            )
        )
    }

    func testExtensionsSidebarSelectionRoutesToPiPackageCatalog() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(contentSource.contains("@StateObject private var extensionsCatalogStore"))
        XCTAssertTrue(contentSource.contains("selectedCustomDestination == .connectedApps"))
        XCTAssertTrue(contentSource.contains("ExtensionsCatalogView("))
        XCTAssertTrue(contentSource.contains("store: extensionsCatalogStore"))
        XCTAssertTrue(contentSource.contains("installedStore: installedExtensionsStore"))
    }

    func testExtensionsCatalogViewProvidesExtensionCategoriesInstalledManagerAndRefresh() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "PiWork/Features/Extensions/Views/ExtensionsCatalogView.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("TextField(L10n.string(\"extensions.search_placeholder\")")
        )
        XCTAssertTrue(source.contains("ForEach(PiExtensionCategory.allCases"))
        XCTAssertTrue(source.contains("LazyVGrid"))
        XCTAssertTrue(source.contains("struct ExtensionsCatalogCard: View"))
        XCTAssertTrue(source.contains("InstalledExtensionsButton"))
        XCTAssertTrue(source.contains("InstalledExtensionsPanel"))
        XCTAssertTrue(source.contains("await installedStore.install(source: item.packageSource)"))
        XCTAssertTrue(source.contains("installedStore.installationError(for: item.packageSource)"))
        XCTAssertTrue(source.contains("Toggle("))
        XCTAssertTrue(source.contains("InWindowFloatingPanel("))
        XCTAssertTrue(source.contains("CatalogInstalledManagerAnchorKey"))
        XCTAssertTrue(source.contains(".anchorPreference("))
        XCTAssertTrue(source.contains("anchorFrame:"))
        XCTAssertTrue(source.contains("isSelected: isPresented"))
        XCTAssertFalse(source.contains(".popover(isPresented:"))
        XCTAssertTrue(source.contains("await store.refresh(request)"))
        XCTAssertTrue(source.contains("NSWorkspace.shared.open"))
        XCTAssertTrue(source.contains("L10n.string(\"extensions.source\")"))
        XCTAssertTrue(source.contains("L10n.string(\"extensions.no_matches\")"))
        // Browsing pages through pi.dev instead of stopping at its first page.
        XCTAssertTrue(source.contains("await store.loadMore()"))
        XCTAssertTrue(source.contains("store.hasMore"))
        XCTAssertTrue(source.contains("L10n.string(\"extensions.load_more\")"))
        XCTAssertFalse(source.contains("ExtensionsCatalogCategory"))
        XCTAssertFalse(source.contains("extensions.category.skills"))
        XCTAssertFalse(source.contains("extensions.category.prompts"))
        XCTAssertFalse(source.contains("extensions.category.themes"))
    }

    func testRequiredPiWebAccessExtensionCannotBeDisabledOrRemoved() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "PiWork/Features/Extensions/Views/ExtensionsCatalogView.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("isRequiredPiWebAccess"))
        XCTAssertTrue(source.contains("if !package.isRequiredPiWebAccess"))
    }

    func testExtensionManagementPanelDoesNotContainPluginConfiguration() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "PiWork/Features/Extensions/Views/ExtensionsCatalogView.swift"
                ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("PiWebAccessConfigurationView"))
        XCTAssertFalse(source.contains("onConfigure:"))
        XCTAssertFalse(source.contains("extensions.pi_web_access.configure"))
    }

    func testSettingsWindowHasDedicatedExtensionSettingsDestination() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/PiWorkApp.swift"),
            encoding: .utf8
        )

        let navigationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Core/UI/AppSettingsNavigation.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(navigationSource.contains("case extensions"))
        XCTAssertTrue(settingsSource.contains("ExtensionSettingsView(store: installedExtensionsStore)"))
        XCTAssertTrue(appSource.contains("installedExtensionsStore: installedExtensionsStore"))
    }

    func testExtensionsCatalogGridAdaptsColumnsToTheAvailableWidth() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "PiWork/Features/Extensions/Views/ExtensionsCatalogView.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                "GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)"
            )
        )
    }

    func testExtensionCardsMatchSkillCatalogInstallStatePlacementAndStyling() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "PiWork/Features/Extensions/Views/ExtensionsCatalogView.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Spacer(minLength: 0)\n\n                installControl"))
        XCTAssertTrue(source.contains("private var installControl: some View"))
        XCTAssertTrue(source.contains(
            "Label(L10n.string(\"extensions.installed_label\"), systemImage: \"checkmark\")"
        ))
        XCTAssertTrue(source.contains("Image(systemName: \"arrow.down\")"))
        XCTAssertTrue(source.contains("Capsule().fill(Color.primary.opacity(0.88))"))
        XCTAssertTrue(source.contains(
            ".frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)"
        ))
    }

    func testPageParserKeepsOnlyExtensionsExtractsKeywordsAndDeduplicatesNames() throws {
        let packages = try ExtensionsCatalogPageParser().parsePage(Data(packagePageHTML.utf8)).items

        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(
            packages.first,
            PiPackageItem(
                name: "@scope/agent-tools",
                summary: "Build & run focused agent tools.",
                author: "alice",
                monthlyDownloads: 12_345,
                published: "2d ago",
                types: [.extensionPackage, .prompt],
                keywords: ["subagent", "developer-tools"]
            )
        )
    }

    func testFilterMatchesDescriptionAndAuthorWithinSelectedExtensionCategory() throws {
        let packages = try ExtensionsCatalogPageParser().parsePage(Data(packagePageHTML.utf8)).items

        let matches = ExtensionsCatalogFilter(
            query: "ALICE tools",
            category: .agents
        ).apply(to: packages)

        XCTAssertEqual(matches.map(\.name), ["@scope/agent-tools"])
    }

    func testExtensionCategoryUsesPublishedKeywordsWithoutGuessingFromDescription() {
        let securityExtension = PiPackageItem(
            name: "pi-guard",
            summary: "A small helper.",
            author: "alice",
            monthlyDownloads: 1,
            published: nil,
            types: [.extensionPackage],
            keywords: ["authorization"]
        )
        let unclassifiedExtension = PiPackageItem(
            name: "pi-helper",
            summary: "Security and autonomous agent helper.",
            author: "bob",
            monthlyDownloads: 1,
            published: nil,
            types: [.extensionPackage],
            keywords: []
        )
        let automationExtension = PiPackageItem(
            name: "pi-goal-audit",
            summary: "A goal runner with verification.",
            author: "carol",
            monthlyDownloads: 1,
            published: nil,
            types: [.extensionPackage],
            keywords: ["goal", "task-planning", "audit"]
        )

        XCTAssertEqual(securityExtension.extensionCategory, .security)
        XCTAssertEqual(unclassifiedExtension.extensionCategory, .other)
        XCTAssertEqual(automationExtension.extensionCategory, .agents)
    }

    func testScopedPackageBuildsPiPageURLAndInstallCommand() {
        let item = PiPackageItem(
            name: "@scope/agent-tools",
            summary: "Agent tools",
            author: "alice",
            monthlyDownloads: 1,
            published: nil,
            types: [.extensionPackage],
            keywords: ["developer-tools"]
        )

        XCTAssertEqual(item.pageURL?.absoluteString, "https://pi.dev/packages/@scope/agent-tools")
        XCTAssertEqual(item.packageSource, "npm:@scope/agent-tools")
        XCTAssertEqual(item.installCommand, "pi install npm:@scope/agent-tools")
    }

    func testCatalogURLPercentEncodesSearchAndKeepsCuratedBrowseFilter() throws {
        let request = ExtensionsCatalogRequest(query: "agent tools & ui")
        let url = try XCTUnwrap(RemoteExtensionsCatalogClient.catalogURL(for: request))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/packages")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "name" })?.value,
            "agent tools & ui"
        )
        // pi.dev drops packages without declared type metadata from
        // `type=extension`, so searches must not send that filter. Regression
        // guard for `pi-pstack-v2` returning an empty result set.
        XCTAssertNil(components.queryItems?.first(where: { $0.name == "type" }))
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "sort" })?.value,
            "downloads"
        )

        let defaultURL = try XCTUnwrap(
            RemoteExtensionsCatalogClient.catalogURL(for: ExtensionsCatalogRequest())
        )
        XCTAssertEqual(
            URLComponents(url: defaultURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "type" })?.value,
            "extension"
        )
    }

    func testCatalogURLAddsThePageParameterOnlyAfterTheFirstPage() throws {
        let request = ExtensionsCatalogRequest()
        let firstPage = try XCTUnwrap(
            RemoteExtensionsCatalogClient.catalogURL(for: request)
        )
        XCTAssertNil(
            URLComponents(url: firstPage, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })
        )

        let thirdPage = try XCTUnwrap(
            RemoteExtensionsCatalogClient.catalogURL(for: request, page: 3)
        )
        XCTAssertEqual(
            URLComponents(url: thirdPage, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value,
            "3"
        )
    }

    func testPageParserKeepsPackagesWithoutDeclaredTypes() throws {
        let packages = try ExtensionsCatalogPageParser().parsePage(
            Data(untypedPackagePageHTML.utf8)
        ).items

        XCTAssertEqual(packages.map(\.name), ["@justjoshn/pi-pstack-v2"])
        XCTAssertEqual(packages.first?.types, [])
        XCTAssertEqual(packages.first?.summary, "Pstack skills for pi.")
    }

    func testPageParserReturnsNoMatchesInsteadOfFailingWhenPiDevReportsZeroResults() throws {
        // A zero-result catalog page is a successful response, not a parsing
        // failure. Throwing here produced the bogus "Unable to search pi.dev"
        // state whenever a search simply had no matches.
        let page = try ExtensionsCatalogPageParser().parsePage(
            Data(noMatchesPageHTML.utf8)
        )

        XCTAssertEqual(page.items, [])
        XCTAssertEqual(page.totalCount, 0)
    }

    func testPageParserReadsTheFilteredResultTotalFromTheCountHeader() throws {
        let page = try ExtensionsCatalogPageParser().parsePage(
            Data(pagedPackagePageHTML.utf8)
        )

        XCTAssertEqual(page.items.map(\.name), ["@scope/agent-tools"])
        // `1-50 / 3174 (of 5683)` → 3174 matching typed extensions.
        XCTAssertEqual(page.totalCount, 3174)
    }

    func testPageParserStillFailsWhenTheCatalogMarkupDisappears() {
        let html = #"<html><body><span class="packages-count">1-50 / 3174</span></body></html>"#

        XCTAssertThrowsError(try ExtensionsCatalogPageParser().parsePage(Data(html.utf8))) { error in
            guard case ExtensionsCatalogParsingError.noPackages = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCachePolicyKeepsFreshSnapshotAndRefreshesExpiredSnapshot() {
        let now = Date(timeIntervalSince1970: 20_000)
        let fresh = ExtensionsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: now.addingTimeInterval(-(6 * 60 * 60 - 1))
        )
        let expired = ExtensionsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: now.addingTimeInterval(-(6 * 60 * 60))
        )
        let policy = ExtensionsCatalogCachePolicy()

        XCTAssertFalse(policy.shouldRefresh(fresh, now: now))
        XCTAssertTrue(policy.shouldRefresh(expired, now: now))
    }

    func testDiskCacheRoundTripsSnapshot() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-extensions-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = DiskExtensionsCatalogCache(
            fileURL: cacheRoot.appendingPathComponent("snapshot.json")
        )
        let snapshot = ExtensionsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: Date(timeIntervalSince1970: 12_345)
        )

        try cache.save(snapshot)

        XCTAssertEqual(try cache.load(), snapshot)
    }

    @MainActor
    func testStoreUsesFreshDefaultSnapshotWithoutNetworkRequest() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let snapshot = ExtensionsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: now.addingTimeInterval(-60)
        )
        let client = StubExtensionsCatalogFetcher(results: [.success([])])
        let store = ExtensionsCatalogStore(
            client: client,
            cache: MemoryExtensionsCatalogCache(snapshot: snapshot)
        )

        await store.load(.init(), now: now)

        XCTAssertEqual(store.items, snapshot.items)
        XCTAssertEqual(store.lastUpdated, snapshot.fetchedAt)
        XCTAssertTrue(client.requests.isEmpty)
    }

    @MainActor
    func testEmptySearchResultIsAnEmptyCatalogNotAParseFailure() async {
        let request = ExtensionsCatalogRequest(query: "no-such-package")
        let client = StubExtensionsCatalogFetcher(results: [.success([])])
        let store = ExtensionsCatalogStore(
            client: client,
            cache: MemoryExtensionsCatalogCache(snapshot: nil)
        )

        await store.load(request)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testEmptyBrowseResponseKeepsPreviousCatalogAndReportsFailure() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let stale = ExtensionsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: now.addingTimeInterval(-(7 * 60 * 60))
        )
        let client = StubExtensionsCatalogFetcher(results: [.success([])])
        let cache = MemoryExtensionsCatalogCache(snapshot: stale)
        let store = ExtensionsCatalogStore(client: client, cache: cache)

        await store.load(.init(), now: now)

        XCTAssertEqual(store.items, stale.items)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(cache.savedSnapshots.isEmpty)
    }

    @MainActor
    func testLoadMoreAppendsTheNextPageUntilTheReportedTotalIsReached() async {
        let firstPage = (0..<3).map { fixtureItem(named: "pi-a\($0)") }
        let secondPage = (0..<2).map { fixtureItem(named: "pi-b\($0)") }
        let client = StubExtensionsCatalogFetcher(pages: [
            .success(ExtensionsCatalogPage(items: firstPage, totalCount: 5)),
            .success(ExtensionsCatalogPage(items: secondPage, totalCount: 5))
        ])
        let store = ExtensionsCatalogStore(
            client: client,
            cache: MemoryExtensionsCatalogCache(snapshot: nil)
        )

        await store.load()
        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.totalCount, 5)
        XCTAssertTrue(store.hasMore)

        await store.loadMore()

        XCTAssertEqual(store.items.map(\.name), (firstPage + secondPage).map(\.name))
        XCTAssertEqual(client.requests.map(\.page), [1, 2])
        XCTAssertFalse(store.hasMore)
        XCTAssertFalse(store.isLoadingMore)
    }

    @MainActor
    func testLoadMoreSkipsDuplicatePackagesAcrossPages() async {
        let firstPage = [fixtureItem(named: "pi-a"), fixtureItem(named: "pi-b")]
        let secondPage = [fixtureItem(named: "pi-b"), fixtureItem(named: "pi-c")]
        let client = StubExtensionsCatalogFetcher(pages: [
            .success(ExtensionsCatalogPage(items: firstPage, totalCount: 4)),
            .success(ExtensionsCatalogPage(items: secondPage, totalCount: 4))
        ])
        let store = ExtensionsCatalogStore(
            client: client,
            cache: MemoryExtensionsCatalogCache(snapshot: nil)
        )

        await store.load()
        await store.loadMore()

        XCTAssertEqual(store.items.map(\.name), ["pi-a", "pi-b", "pi-c"])
        XCTAssertTrue(store.hasMore)
    }

    @MainActor
    func testLoadMoreStopsWhenPiDevRunsOutOfPagesBeforeItsReportedTotal() async {
        let firstPage = [fixtureItem(named: "pi-a")]
        let client = StubExtensionsCatalogFetcher(pages: [
            .success(ExtensionsCatalogPage(items: firstPage, totalCount: 10)),
            .success(ExtensionsCatalogPage(items: [], totalCount: 10))
        ])
        let store = ExtensionsCatalogStore(
            client: client,
            cache: MemoryExtensionsCatalogCache(snapshot: nil)
        )

        await store.load()
        XCTAssertTrue(store.hasMore)

        await store.loadMore()

        XCTAssertEqual(store.items.map(\.name), ["pi-a"])
        XCTAssertFalse(store.hasMore)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testLoadMoreStopsWhenPiDevRepeatsAPageItAlreadySent() async {
        let firstPage = [fixtureItem(named: "pi-a"), fixtureItem(named: "pi-b")]
        let client = StubExtensionsCatalogFetcher(pages: [
            .success(ExtensionsCatalogPage(items: firstPage, totalCount: 100)),
            .success(ExtensionsCatalogPage(items: firstPage, totalCount: 100))
        ])
        let store = ExtensionsCatalogStore(
            client: client,
            cache: MemoryExtensionsCatalogCache(snapshot: nil)
        )

        await store.load()
        XCTAssertTrue(store.hasMore)

        await store.loadMore()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertFalse(store.hasMore)
    }

    @MainActor
    func testLoadMoreIsANoOpWithoutAReportedTotal() async {
        let client = StubExtensionsCatalogFetcher(results: [.success(fixtureItems())])
        let store = ExtensionsCatalogStore(
            client: client,
            cache: MemoryExtensionsCatalogCache(snapshot: nil)
        )

        await store.load()
        XCTAssertFalse(store.hasMore)

        await store.loadMore()

        XCTAssertEqual(client.requests.map(\.page), [1])
    }

    @MainActor
    func testStoreLoadsSearchAndCategoryFromRemote() async {
        let request = ExtensionsCatalogRequest(query: "agent")
        let client = StubExtensionsCatalogFetcher(results: [.success(fixtureItems())])
        let store = ExtensionsCatalogStore(
            client: client,
            cache: MemoryExtensionsCatalogCache(snapshot: nil)
        )

        await store.load(request)

        XCTAssertEqual(client.requests.map(\.request), [request])
        XCTAssertEqual(client.requests.map(\.ignoringCache), [false])
        XCTAssertEqual(store.items, fixtureItems())
        XCTAssertEqual(store.activeRequest, request)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testManualRefreshBypassesURLAndMemoryCaches() async {
        let request = ExtensionsCatalogRequest()
        let client = StubExtensionsCatalogFetcher(results: [
            .success(fixtureItems()),
            .success(Array(fixtureItems().reversed()))
        ])
        let cache = MemoryExtensionsCatalogCache(snapshot: nil)
        let store = ExtensionsCatalogStore(client: client, cache: cache)

        await store.load(request)
        await store.refresh(request)

        XCTAssertEqual(client.requests.map(\.ignoringCache), [false, true])
        XCTAssertEqual(store.items, Array(fixtureItems().reversed()))
        XCTAssertEqual(cache.savedSnapshots.count, 2)
    }

    @MainActor
    func testCancelledLoadClearsLoadingStateAndCanRetry() async {
        let client = StubExtensionsCatalogFetcher(results: [
            .failure(CancellationError()),
            .success(fixtureItems())
        ])
        let store = ExtensionsCatalogStore(
            client: client,
            cache: MemoryExtensionsCatalogCache(snapshot: nil)
        )

        await store.load()

        XCTAssertFalse(store.isLoading)

        await store.load()

        XCTAssertEqual(store.items, fixtureItems())
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testInstalledExtensionsStoreLoadsUpdatesAndRemovesThroughAgentHost() async {
        let package = AgentHostInstalledExtensionPackage(
            source: "npm:pi-agent-tools",
            scope: .user,
            filtered: false,
            installedPath: "/tmp/pi-agent-tools",
            enabled: true
        )
        let service = StubInstalledExtensionsService(packages: [package])
        let store = InstalledExtensionsStore(service: service)

        await store.load()
        XCTAssertEqual(store.packages, [package])

        await store.update(package)
        let actionsAfterUpdate = await service.recordedActions()
        XCTAssertEqual(actionsAfterUpdate, [.list, .update(package)])

        await store.remove(package)
        XCTAssertTrue(store.packages.isEmpty)
        let actionsAfterRemoval = await service.recordedActions()
        XCTAssertEqual(
            actionsAfterRemoval,
            [.list, .update(package), .remove(package)]
        )
    }

    @MainActor
    func testInstalledExtensionsStoreInstallsCatalogPackageThroughAgentHost() async {
        let service = StubInstalledExtensionsService(packages: [])
        let store = InstalledExtensionsStore(service: service)

        await store.install(source: "npm:pi-agent-tools")

        XCTAssertEqual(store.packages.map(\.source), ["npm:pi-agent-tools"])
        XCTAssertTrue(store.isInstalled(source: "npm:pi-agent-tools"))
        let actions = await service.recordedActions()
        XCTAssertEqual(
            actions,
            [.install("npm:pi-agent-tools")]
        )
    }

    @MainActor
    func testInstalledExtensionsStoreTogglesPackageWithoutRemovingIt() async {
        let package = AgentHostInstalledExtensionPackage(
            source: "npm:pi-agent-tools",
            scope: .user,
            filtered: false,
            installedPath: "/tmp/pi-agent-tools",
            enabled: true
        )
        let service = StubInstalledExtensionsService(packages: [package])
        let store = InstalledExtensionsStore(service: service)
        await store.load()

        await store.setEnabled(package, enabled: false)

        XCTAssertEqual(store.packages.count, 1)
        XCTAssertFalse(try! XCTUnwrap(store.packages.first).enabled)
        let actions = await service.recordedActions()
        XCTAssertEqual(
            actions,
            [.list, .setEnabled(package, false)]
        )
    }

    @MainActor
    func testInstalledExtensionsStoreLoadsAndUpdatesGenericSettings() async {
        let package = AgentHostInstalledExtensionPackage(
            source: "npm:pi-agent-tools",
            scope: .user,
            filtered: false,
            installedPath: "/tmp/pi-agent-tools",
            enabled: true
        )
        let setting = AgentHostExtensionSettings(
            source: package.source,
            scope: package.scope,
            configurable: true,
            fields: [
                AgentHostExtensionSettingField(
                    path: "/enabled",
                    title: "Enabled",
                    description: nil,
                    kind: .boolean,
                    value: "true",
                    defaultValue: "true",
                    hasValue: false,
                    options: nil,
                    group: nil,
                    required: false,
                    readOnly: false,
                    advanced: false
                )
            ]
        )
        let service = StubInstalledExtensionsService(
            packages: [package],
            settings: [setting]
        )
        let store = InstalledExtensionsStore(service: service)

        await store.loadSettings()
        XCTAssertEqual(store.settings, [setting])

        await store.updateSettings(
            setting,
            changes: [AgentHostExtensionSettingChange(path: "/enabled", value: "false")]
        )

        XCTAssertEqual(store.settings[0].fields[0].value, "false")
        let actions = await service.recordedActions()
        XCTAssertEqual(
            actions,
            [
                .listSettings,
                .updateSettings(
                    setting,
                    [AgentHostExtensionSettingChange(path: "/enabled", value: "false")]
                )
            ]
        )
    }

    private var packagePageHTML: String {
        #"""
        <html><body><div class="packages-grid">
          <article class="surface-panel content-card" data-package-card="true"
            data-package-name="@scope/agent-tools" data-package-types="extension prompt"
            data-package-search="@scope/agent-tools build &amp; run focused agent tools. alice extension prompt subagent developer-tools"
            data-package-downloads="12345">
            <div class="packages-card-body">
              <h3 class="packages-name"><a href="/packages/@scope/agent-tools">@scope/agent-tools</a></h3>
              <p class="packages-desc">Build &amp; run focused agent tools.</p>
              <div class="packages-meta"><span>alice</span><span>12.3K/mo</span><span>2d ago</span></div>
            </div>
          </article>
          <article data-package-card="true" data-package-name="plain-package"
            data-package-types="skill theme"
            data-package-search="plain-package a plain package. bob skill theme utility"
            data-package-downloads="90">
            <p class="packages-desc">A plain package.</p>
            <div class="packages-meta"><span>bob</span><span>90/mo</span><span>1mo ago</span></div>
          </article>
          <article data-package-card="true" data-package-name="@scope/agent-tools"
            data-package-types="extension"
            data-package-search="@scope/agent-tools duplicate. alice extension duplicate"
            data-package-downloads="12345">
            <p class="packages-desc">Duplicate.</p>
            <div class="packages-meta"><span>alice</span><span>12.3K/mo</span><span>2d ago</span></div>
          </article>
        </div></body></html>
        """#
    }

    private var untypedPackagePageHTML: String {
        #"""
        <html><body><div class="packages-grid">
          <article class="surface-panel content-card" data-package-card="true"
            data-package-name="@justjoshn/pi-pstack-v2" data-package-types=""
            data-package-search="@justjoshn/pi-pstack-v2 pstack skills and workflow. justjoshn pstack poteto-mode"
            data-package-downloads="42">
            <div class="packages-card-body">
              <h3 class="packages-name"><a href="/packages/@justjoshn/pi-pstack-v2">@justjoshn/pi-pstack-v2</a></h3>
              <p class="packages-desc">Pstack skills for pi.</p>
              <div class="packages-meta"><span>justjoshn</span><span>42/mo</span><span>3d ago</span></div>
            </div>
          </article>
          <article data-package-card="true" data-package-name="@casualjim/pi-pstack"
            data-package-types="skill"
            data-package-search="@casualjim/pi-pstack pstack skills. casualjim skill pstack"
            data-package-downloads="7">
            <p class="packages-desc">Pstack skills only.</p>
            <div class="packages-meta"><span>casualjim</span><span>7/mo</span><span>5d ago</span></div>
          </article>
        </div></body></html>
        """#
    }

    private var noMatchesPageHTML: String {
        #"""
        <html><body><main><section class="surface-panel content-card packages-index-card">
          <header><span class="packages-count">0 / 5683</span></header>
          <p class="packages-empty">No packages match this filter.</p>
        </section></main></body></html>
        """#
    }

    private var pagedPackagePageHTML: String {
        #"""
        <html><body><section class="packages-index-card">
          <header><span class="packages-count">1-50 / 3174 (of 5683)</span></header>
          <div class="packages-grid">
            <article data-package-card="true" data-package-name="@scope/agent-tools"
              data-package-types="extension"
              data-package-search="@scope/agent-tools build and run focused agent tools. alice extension subagent"
              data-package-downloads="12345">
              <p class="packages-desc">Build &amp; run focused agent tools.</p>
              <div class="packages-meta"><span>alice</span><span>12.3K/mo</span><span>2d ago</span></div>
            </article>
          </div>
        </section></body></html>
        """#
    }

    private func fixtureItem(named name: String) -> PiPackageItem {
        PiPackageItem(
            name: name,
            summary: "Summary for \(name)",
            author: "alice",
            monthlyDownloads: 1,
            published: nil,
            types: []
        )
    }

    private func fixtureItems() -> [PiPackageItem] {
        [
            PiPackageItem(
                name: "pi-agent-tools",
                summary: "Focused agent tools",
                author: "alice",
                monthlyDownloads: 12_345,
                published: "2d ago",
                types: [.extensionPackage],
                keywords: ["developer-tools"]
            ),
            PiPackageItem(
                name: "pi-security",
                summary: "Permission controls",
                author: "bob",
                monthlyDownloads: 900,
                published: "1mo ago",
                types: [.extensionPackage],
                keywords: ["permissions"]
            )
        ]
    }
}

private actor StubInstalledExtensionsService: InstalledExtensionsServicing {
    enum Action: Equatable {
        case list
        case install(String)
        case setEnabled(AgentHostInstalledExtensionPackage, Bool)
        case update(AgentHostInstalledExtensionPackage)
        case remove(AgentHostInstalledExtensionPackage)
        case listSettings
        case updateSettings(
            AgentHostExtensionSettings,
            [AgentHostExtensionSettingChange]
        )
    }

    private var packages: [AgentHostInstalledExtensionPackage]
    private var settings: [AgentHostExtensionSettings]
    private var actions: [Action] = []
    private var updateResult: Result<[AgentHostInstalledExtensionPackage], Error>?

    init(
        packages: [AgentHostInstalledExtensionPackage],
        settings: [AgentHostExtensionSettings] = []
    ) {
        self.packages = packages
        self.settings = settings
    }

    func listExtensionSettings(requestID: String) async throws
        -> [AgentHostExtensionSettings] {
        actions.append(.listSettings)
        return settings
    }

    func updateExtensionSettings(
        source: String,
        scope: AgentHostExtensionPackageScope,
        changes: [AgentHostExtensionSettingChange],
        requestID: String
    ) async throws -> AgentHostExtensionSettings {
        let index = settings.firstIndex {
            $0.source == source && $0.scope == scope
        }!
        let current = settings[index]
        actions.append(.updateSettings(current, changes))
        let values = Dictionary(uniqueKeysWithValues: changes.compactMap { change in
            change.value.map { (change.path, $0) }
        })
        let updated = AgentHostExtensionSettings(
            source: current.source,
            scope: current.scope,
            configurable: current.configurable,
            fields: current.fields.map { field in
                guard let value = values[field.path] else { return field }
                return AgentHostExtensionSettingField(
                    path: field.path,
                    title: field.title,
                    description: field.description,
                    kind: field.kind,
                    value: field.kind == .secure ? nil : value,
                    defaultValue: field.defaultValue,
                    hasValue: true,
                    options: field.options,
                    group: field.group,
                    required: field.required,
                    readOnly: field.readOnly,
                    advanced: field.advanced
                )
            }
        )
        settings[index] = updated
        return updated
    }

    func listInstalledExtensions(requestID: String) async throws
        -> [AgentHostInstalledExtensionPackage] {
        actions.append(.list)
        return packages
    }

    func installExtension(
        source: String,
        requestID: String
    ) async throws -> [AgentHostInstalledExtensionPackage] {
        actions.append(.install(source))
        if !packages.contains(where: { $0.source == source && $0.scope == .user }) {
            packages.append(AgentHostInstalledExtensionPackage(
                source: source,
                scope: .user,
                filtered: false,
                installedPath: "/tmp/\(source.dropFirst("npm:".count))",
                enabled: true
            ))
        }
        return packages
    }

    func setInstalledExtensionEnabled(
        source: String,
        scope: AgentHostExtensionPackageScope,
        enabled: Bool,
        requestID: String
    ) async throws -> [AgentHostInstalledExtensionPackage] {
        guard let index = packages.firstIndex(where: {
            $0.source == source && $0.scope == scope
        }) else { return packages }
        let package = packages[index]
        actions.append(.setEnabled(package, enabled))
        packages[index] = AgentHostInstalledExtensionPackage(
            source: package.source,
            scope: package.scope,
            filtered: !enabled,
            installedPath: package.installedPath,
            enabled: enabled,
            version: package.version
        )
        return packages
    }

    func updateInstalledExtension(
        source: String,
        scope: AgentHostExtensionPackageScope,
        requestID: String
    ) async throws -> [AgentHostInstalledExtensionPackage] {
        guard let package = packages.first(where: {
            $0.source == source && $0.scope == scope
        }) else { return packages }
        actions.append(.update(package))
        if let updateResult { packages = try updateResult.get() }
        return packages
    }

    func removeInstalledExtension(
        source: String,
        scope: AgentHostExtensionPackageScope,
        requestID: String
    ) async throws -> [AgentHostInstalledExtensionPackage] {
        guard let package = packages.first(where: {
            $0.source == source && $0.scope == scope
        }) else { return packages }
        actions.append(.remove(package))
        packages.removeAll { $0 == package }
        return packages
    }

    func recordedActions() -> [Action] { actions }

    func setUpdateResult(_ result: Result<[AgentHostInstalledExtensionPackage], Error>) {
        updateResult = result
    }
}

private final class StubExtensionsCatalogFetcher: ExtensionsCatalogFetching {
    struct Request: Equatable {
        let request: ExtensionsCatalogRequest
        let page: Int
        let ignoringCache: Bool
    }

    private var pages: [Result<ExtensionsCatalogPage, Error>]
    private(set) var requests: [Request] = []

    init(pages: [Result<ExtensionsCatalogPage, Error>]) {
        self.pages = pages
    }

    convenience init(
        results: [Result<[PiPackageItem], Error>],
        totalCount: Int? = nil
    ) {
        self.init(pages: results.map { result in
            result.map { ExtensionsCatalogPage(items: $0, totalCount: totalCount) }
        })
    }

    func fetchPackages(
        for request: ExtensionsCatalogRequest,
        page: Int,
        ignoringCache: Bool
    ) async throws -> ExtensionsCatalogPage {
        requests.append(Request(
            request: request,
            page: page,
            ignoringCache: ignoringCache
        ))
        return try pages.removeFirst().get()
    }
}

private final class MemoryExtensionsCatalogCache: ExtensionsCatalogCaching {
    private(set) var snapshot: ExtensionsCatalogSnapshot?
    private(set) var savedSnapshots: [ExtensionsCatalogSnapshot] = []

    init(snapshot: ExtensionsCatalogSnapshot?) {
        self.snapshot = snapshot
    }

    func load() throws -> ExtensionsCatalogSnapshot? { snapshot }

    func save(_ snapshot: ExtensionsCatalogSnapshot) throws {
        self.snapshot = snapshot
        savedSnapshots.append(snapshot)
    }
}
