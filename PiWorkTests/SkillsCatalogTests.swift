import XCTest
@testable import PiWork

final class SkillsCatalogTests: XCTestCase {
    func testSkillsCatalogFeatureHasDedicatedModelAndView() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repositoryRoot
                    .appendingPathComponent("PiWork/Features/Skills/SkillsCatalog.swift")
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repositoryRoot
                    .appendingPathComponent("PiWork/Features/Skills/Views/SkillsCatalogView.swift")
                    .path
            )
        )
    }

    func testSkillsCatalogDefinesParsingFilteringAndCacheBoundaries() throws {
        let source = try String(contentsOf: modelURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("struct SkillsCatalogItem"))
        XCTAssertTrue(source.contains("enum SkillsCatalogCategory"))
        XCTAssertTrue(source.contains("struct SkillsCatalogPageParser"))
        XCTAssertTrue(source.contains("struct SkillsCatalogFilter"))
        XCTAssertTrue(source.contains("struct SkillsCatalogCachePolicy"))
        XCTAssertTrue(source.contains("struct SkillsCatalogSnapshot"))
        XCTAssertTrue(source.contains("protocol SkillsCatalogFetching"))
        XCTAssertTrue(source.contains("protocol SkillsCatalogCaching"))
        XCTAssertTrue(source.contains("struct RemoteSkillsCatalogClient"))
        XCTAssertTrue(source.contains("struct DiskSkillsCatalogCache"))
        XCTAssertTrue(source.contains("final class SkillsCatalogStore"))
    }

    func testSkillsSidebarSelectionRoutesToDedicatedCatalogView() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Sidebar/Views/SidebarView.swift"
            ),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )
        let viewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Skills/Views/SkillsCatalogView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(sidebarSource.contains("enum SidebarCustomDestination"))
        XCTAssertTrue(sidebarSource.contains("onSelectCustomDestination"))
        XCTAssertTrue(contentSource.contains("selectedCustomDestination == .skills"))
        XCTAssertTrue(contentSource.contains("SkillsCatalogView("))
        XCTAssertTrue(viewSource.contains("struct SkillsCatalogView: View"))
    }

    func testSkillsCatalogViewProvidesSearchFiltersCardsAndRefresh() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("PiWork/Features/Skills/Views/SkillsCatalogView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("L10n.string(\"skills.search_placeholder\")"))
        XCTAssertTrue(source.contains("ForEach(SkillsCatalogCategory.allCases"))
        XCTAssertTrue(source.contains("LazyVGrid"))
        XCTAssertTrue(source.contains("struct SkillsCatalogCard: View"))
        XCTAssertTrue(source.contains("await store.refresh()"))
        XCTAssertTrue(source.contains("NSWorkspace.shared.open"))
        XCTAssertTrue(source.contains("store.errorMessage"))
        XCTAssertTrue(source.contains("L10n.string(\"skills.no_matches\")"))
        XCTAssertTrue(source.contains(".task(id: query)"))
        XCTAssertTrue(source.contains("await store.search(query)"))
    }

    func testSkillsCatalogGridAdaptsColumnsToTheAvailableWidth() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("PiWork/Features/Skills/Views/SkillsCatalogView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                "GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)"
            )
        )
    }

    func testSkillsHeaderProvidesInstalledSkillsManager() throws {
        let viewSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("PiWork/Features/Skills/Views/SkillsCatalogView.swift"),
            encoding: .utf8
        )
        let modelSource = try String(contentsOf: modelURL(), encoding: .utf8)

        XCTAssertTrue(viewSource.contains("Image(systemName: \"tray.full\")"))
        XCTAssertTrue(viewSource.contains("InWindowFloatingPanel("))
        XCTAssertTrue(viewSource.contains("CatalogInstalledManagerAnchorKey"))
        XCTAssertTrue(viewSource.contains(".anchorPreference("))
        XCTAssertTrue(viewSource.contains("anchorFrame:"))
        XCTAssertTrue(viewSource.contains("isSelected: isPresented"))
        XCTAssertFalse(viewSource.contains(".popover(isPresented:"))
        XCTAssertTrue(viewSource.contains("struct InstalledSkillsPanel: View"))
        XCTAssertTrue(viewSource.contains("Toggle(isOn:"))
        XCTAssertTrue(viewSource.contains("await store.setEnabled"))
        XCTAssertTrue(viewSource.contains("await installedSkillsStore.install"))
        XCTAssertFalse(viewSource.contains(".sheet(isPresented: $isInstalledSkillsPresented)"))
        XCTAssertTrue(modelSource.contains("struct InstalledSkill"))
        XCTAssertTrue(modelSource.contains("struct InstalledSkillsScanner"))
        XCTAssertTrue(modelSource.contains("struct SkillsCLIInstallCommand"))
        XCTAssertTrue(modelSource.contains("protocol SkillsInstalling"))
        XCTAssertTrue(modelSource.contains("protocol InstalledSkillEnablementManaging"))
        XCTAssertTrue(modelSource.contains("protocol InstalledSkillRemoving"))
        XCTAssertTrue(modelSource.contains("final class InstalledSkillsStore"))
    }

    func testInstalledSkillsScannerReadsPiAndSharedSkillsAndDeduplicatesAliases() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-installed-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let piDirectory = root.appendingPathComponent(".pi/agent/skills")
        let sharedDirectory = root.appendingPathComponent(".agents/skills")
        let sharedSkillDirectory = sharedDirectory.appendingPathComponent("shared-skill")
        let piSkillFile = piDirectory.appendingPathComponent("pi-only.md")

        try writeSkill(
            at: sharedSkillDirectory.appendingPathComponent("SKILL.md"),
            contents: """
            ---
            name: Shared Skill
            description: >
              Shared across agent
              harnesses.
            ---
            """
        )
        try writeSkill(
            at: piSkillFile,
            contents: """
            ---
            name: "Pi Only"
            description: A direct markdown skill.
            ---
            """
        )
        try FileManager.default.createSymbolicLink(
            at: piDirectory.appendingPathComponent("shared-skill"),
            withDestinationURL: sharedSkillDirectory
        )

        let skills = try InstalledSkillsScanner(
            piSkillsDirectory: piDirectory,
            sharedSkillsDirectory: sharedDirectory
        ).scan()

        XCTAssertEqual(skills.map(\.name), ["Pi Only", "Shared Skill"])
        let sharedSkill = try XCTUnwrap(skills.first(where: { $0.name == "Shared Skill" }))
        XCTAssertEqual(sharedSkill.description, "Shared across agent harnesses.")
        XCTAssertEqual(
            Set(sharedSkill.installations.map(\.source)),
            Set([InstalledSkillSource.piAgent, .sharedAgents])
        )
        XCTAssertEqual(
            sharedSkill.fileURL,
            sharedSkillDirectory.appendingPathComponent("SKILL.md").resolvingSymlinksInPath()
        )
    }

    func testInstalledSkillsScannerIgnoresSharedRootMarkdownFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-installed-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let piDirectory = root.appendingPathComponent(".pi/agent/skills")
        let sharedDirectory = root.appendingPathComponent(".agents/skills")

        try writeSkill(
            at: piDirectory.appendingPathComponent("included.md"),
            contents: "---\nname: Included\ndescription: Included by Pi.\n---"
        )
        try writeSkill(
            at: sharedDirectory.appendingPathComponent("ignored.md"),
            contents: "---\nname: Ignored\ndescription: Ignored by Pi.\n---"
        )

        let skills = try InstalledSkillsScanner(
            piSkillsDirectory: piDirectory,
            sharedSkillsDirectory: sharedDirectory
        ).scan()

        XCTAssertEqual(skills.map(\.name), ["Included"])
    }

    func testTrashRemoverUsesInstallationEntriesInsteadOfResolvedSkillFile() async throws {
        let piEntry = URL(fileURLWithPath: "/tmp/pi-skills/example")
        let sharedEntry = URL(fileURLWithPath: "/tmp/agent-skills/example")
        let skill = InstalledSkill(
            id: "/tmp/resolved/example/SKILL.md",
            name: "Example",
            description: nil,
            fileURL: URL(fileURLWithPath: "/tmp/resolved/example/SKILL.md"),
            installations: [
                InstalledSkillInstallation(source: .piAgent, url: piEntry),
                InstalledSkillInstallation(source: .sharedAgents, url: sharedEntry),
                InstalledSkillInstallation(source: .sharedAgents, url: sharedEntry)
            ]
        )
        let recorder = RecycledURLsRecorder()
        let remover = TrashInstalledSkillRemover { recorder.urls = $0 }

        try await remover.remove(skill)

        XCTAssertEqual(recorder.urls, [piEntry, sharedEntry])
        XCTAssertFalse(recorder.urls.contains(skill.fileURL))
    }

    @MainActor
    func testInstalledSkillsStoreReloadsAfterRemoval() async {
        let skill = InstalledSkill(
            id: "/tmp/example/SKILL.md",
            name: "Example",
            description: nil,
            fileURL: URL(fileURLWithPath: "/tmp/example/SKILL.md"),
            installations: [
                InstalledSkillInstallation(
                    source: .sharedAgents,
                    url: URL(fileURLWithPath: "/tmp/example")
                )
            ]
        )
        let scanner = SequencedInstalledSkillsScanner(results: [[skill], []])
        let remover = StubInstalledSkillRemover()
        let store = InstalledSkillsStore(scanner: scanner, remover: remover)

        store.reload()
        await store.remove(skill)

        XCTAssertEqual(remover.removedSkills, [skill])
        XCTAssertTrue(store.skills.isEmpty)
        XCTAssertEqual(scanner.scanCount, 2)
    }

    func testSkillsCLIInstallCommandTargetsTheSelectedSkillAndPiGlobally() {
        let item = SkillsCatalogItem(
            source: "vercel-labs/skills",
            slug: "find-skills",
            name: "Find Skills",
            installs: 1,
            isOfficial: false
        )

        let command = SkillsCLIInstallCommand(item: item)

        XCTAssertEqual(command.executableName, "npx")
        XCTAssertEqual(command.arguments, [
            "-y", "skills", "add", "vercel-labs/skills",
            "--skill", "find-skills", "--global", "--agent", "pi", "--yes"
        ])
    }

    func testManagedIgnoreFileDisablesAndReenablesEverySkillInstallation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-skill-enablement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let piDirectory = root.appendingPathComponent(".pi/agent/skills")
        let sharedDirectory = root.appendingPathComponent(".agents/skills")
        let piSkill = piDirectory.appendingPathComponent("example")
        let sharedSkill = sharedDirectory.appendingPathComponent("nested/example")
        try FileManager.default.createDirectory(at: piSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedSkill, withIntermediateDirectories: true)
        let installations = [
            InstalledSkillInstallation(source: .piAgent, url: piSkill),
            InstalledSkillInstallation(source: .sharedAgents, url: sharedSkill)
        ]
        let manager = ManagedInstalledSkillEnablement(
            piSkillsDirectory: piDirectory,
            sharedSkillsDirectory: sharedDirectory
        )

        try manager.setEnabled(false, for: installations)

        XCTAssertEqual(
            try manager.disabledPatterns(),
            [
                .piAgent: ["/example/"],
                .sharedAgents: ["/nested/example/"]
            ]
        )
        let existingUserRule = "scratch/\n"
        try existingUserRule.write(
            to: piDirectory.appendingPathComponent(".ignore"),
            atomically: true,
            encoding: .utf8
        )
        try manager.setEnabled(false, for: [installations[0]])
        try manager.setEnabled(true, for: installations)

        XCTAssertEqual(try manager.disabledPatterns(), [:])
        XCTAssertEqual(
            try String(
                contentsOf: piDirectory.appendingPathComponent(".ignore"),
                encoding: .utf8
            ),
            existingUserRule
        )
    }

    func testInstalledSkillsScannerReportsManagedIgnoredSkillAsDisabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-disabled-skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let piDirectory = root.appendingPathComponent(".pi/agent/skills")
        let sharedDirectory = root.appendingPathComponent(".agents/skills")
        let skillDirectory = piDirectory.appendingPathComponent("example")
        try writeSkill(
            at: skillDirectory.appendingPathComponent("SKILL.md"),
            contents: "---\nname: example\ndescription: Example skill.\n---"
        )
        let manager = ManagedInstalledSkillEnablement(
            piSkillsDirectory: piDirectory,
            sharedSkillsDirectory: sharedDirectory
        )
        try manager.setEnabled(
            false,
            for: [InstalledSkillInstallation(source: .piAgent, url: skillDirectory)]
        )

        let skill = try XCTUnwrap(InstalledSkillsScanner(
            piSkillsDirectory: piDirectory,
            sharedSkillsDirectory: sharedDirectory
        ).scan().first)

        XCTAssertFalse(skill.isEnabled)
        XCTAssertFalse(skill.installations[0].isEnabled)
    }

    @MainActor
    func testInstalledSkillsStoreInstallsThenReloadsDownloadedSkills() async {
        let item = SkillsCatalogItem(
            source: "vercel-labs/skills",
            slug: "find-skills",
            name: "Find Skills",
            installs: 1,
            isOfficial: false
        )
        let installed = InstalledSkill(
            id: "/tmp/find-skills/SKILL.md",
            name: "find-skills",
            description: "Find skills.",
            fileURL: URL(fileURLWithPath: "/tmp/find-skills/SKILL.md"),
            installations: [
                InstalledSkillInstallation(
                    source: .piAgent,
                    url: URL(fileURLWithPath: "/tmp/find-skills")
                )
            ]
        )
        let scanner = SequencedInstalledSkillsScanner(results: [[], [installed]])
        let installer = StubSkillsInstaller()
        let store = InstalledSkillsStore(
            scanner: scanner,
            installer: installer,
            enablementManager: StubInstalledSkillEnablementManager(),
            remover: StubInstalledSkillRemover()
        )
        store.reload()

        await store.install(item)

        XCTAssertEqual(installer.installedItems, [item])
        XCTAssertEqual(store.skills, [installed])
        XCTAssertTrue(store.isInstalled(item))
        XCTAssertNil(store.installingSkillID)
        XCTAssertEqual(scanner.scanCount, 2)
    }

    @MainActor
    func testInstalledSkillsStorePersistsToggleAndPublishesNewState() async throws {
        let skill = InstalledSkill(
            id: "/tmp/example/SKILL.md",
            name: "example",
            description: nil,
            fileURL: URL(fileURLWithPath: "/tmp/example/SKILL.md"),
            installations: [
                InstalledSkillInstallation(
                    source: .sharedAgents,
                    url: URL(fileURLWithPath: "/tmp/example")
                )
            ]
        )
        let scanner = SequencedInstalledSkillsScanner(results: [[skill]])
        let manager = StubInstalledSkillEnablementManager()
        let store = InstalledSkillsStore(
            scanner: scanner,
            installer: StubSkillsInstaller(),
            enablementManager: manager,
            remover: StubInstalledSkillRemover()
        )
        store.reload()

        await store.setEnabled(false, for: skill)

        XCTAssertEqual(manager.changes.count, 1)
        XCTAssertEqual(manager.changes.first?.enabled, false)
        XCTAssertEqual(manager.changes.first?.installations, skill.installations)
        XCTAssertFalse(try XCTUnwrap(store.skills.first).isEnabled)
        XCTAssertFalse(store.isWorking(on: skill))
    }

    @MainActor
    func testDisabledSkillIsReenabledBeforeItsFilesAreRemoved() async {
        let installation = InstalledSkillInstallation(
            source: .sharedAgents,
            url: URL(fileURLWithPath: "/tmp/example"),
            isEnabled: false
        )
        let skill = InstalledSkill(
            id: "/tmp/example/SKILL.md",
            name: "example",
            description: nil,
            fileURL: URL(fileURLWithPath: "/tmp/example/SKILL.md"),
            installations: [installation]
        )
        let events = InstalledSkillOperationEvents()
        let store = InstalledSkillsStore(
            scanner: SequencedInstalledSkillsScanner(results: [[skill], []]),
            installer: StubSkillsInstaller(),
            enablementManager: OrderedInstalledSkillEnablementManager(events: events),
            remover: OrderedInstalledSkillRemover(events: events)
        )
        store.reload()

        await store.remove(skill)

        XCTAssertEqual(events.values, ["enable", "remove"])
        XCTAssertTrue(store.skills.isEmpty)
    }

    func testSkillsCatalogUsesCompactTopInset() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("PiWork/Features/Skills/Views/SkillsCatalogView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".padding(.top, 48)"))
        XCTAssertFalse(source.contains(".padding(.top, 72)"))
    }

    func testSkillsCatalogCardShowsSummaryInAtMostThreeLines() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("PiWork/Features/Skills/Views/SkillsCatalogView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Text(displaySummary)"))
        XCTAssertTrue(source.contains("L10n.string(\"skills.summary_unavailable\")"))
        XCTAssertTrue(source.contains(".lineLimit(3, reservesSpace: true)"))
        XCTAssertTrue(source.contains(".truncationMode(.tail)"))
        XCTAssertTrue(source.contains("await store.loadSummary(for: item.id)"))
        XCTAssertTrue(source.contains(".task(id: item.needsSummary)"))
        XCTAssertFalse(source.contains("的可复用 Agent 技能"))
    }

    func testPageParserExtractsEscapedFlightPayloadAndDeduplicatesSkills() throws {
        let html = #"""
        <html><body>
        <script>self.__next_f.push([1,"5:[{\"source\":\"openai/skills\",\"skillId\":\"openai-docs\",\"name\":\"OpenAI Docs\",\"installs\":3200,\"weeklyInstalls\":[10,20],\"isOfficial\":true},{\"source\":\"vercel-labs/skills\",\"skillId\":\"find-skills\",\"name\":\"find-skills\",\"installs\":24531,\"weeklyInstalls\":[90,110]},{\"source\":\"openai/skills\",\"skillId\":\"openai-docs\",\"name\":\"OpenAI Docs\",\"installs\":3200,\"weeklyInstalls\":[10,20],\"isOfficial\":true}]"])</script>
        </body></html>
        """#

        let skills = try SkillsCatalogPageParser().parse(Data(html.utf8))

        XCTAssertEqual(skills.count, 2)
        XCTAssertEqual(
            skills.first,
            SkillsCatalogItem(
                source: "openai/skills",
                slug: "openai-docs",
                name: "OpenAI Docs",
                installs: 3_200,
                isOfficial: true
            )
        )
        XCTAssertEqual(skills.last?.id, "vercel-labs/skills/find-skills")
    }

    func testSearchParserExtractsSkillsFromAPIResponse() throws {
        let response = #"""
        {
          "query": "ego-lite",
          "searchType": "fuzzy",
          "skills": [
            {
              "id": "citrolabs/ego-lite/ego-browser",
              "skillId": "ego-browser",
              "name": "ego-browser",
              "installs": 3581,
              "source": "citrolabs/ego-lite"
            }
          ],
          "count": 1,
          "duration_ms": 12
        }
        """#

        let skills = try SkillsCatalogSearchParser().parse(Data(response.utf8))

        XCTAssertEqual(
            skills,
            [
                SkillsCatalogItem(
                    source: "citrolabs/ego-lite",
                    slug: "ego-browser",
                    name: "ego-browser",
                    installs: 3_581,
                    isOfficial: false
                )
            ]
        )
    }

    func testSearchURLPercentEncodesQueryAndLimitsResults() throws {
        let url = try XCTUnwrap(
            RemoteSkillsCatalogSearchClient.searchURL(query: "ego lite & ui")
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/api/search")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "ego lite & ui")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "100")
    }

    func testSearchResultFromWebsiteUsesSkillsSiteRoute() {
        let item = SkillsCatalogItem(
            source: "skills.volces.com",
            slug: "ego-browser",
            name: "ego-browser",
            installs: 1,
            isOfficial: false
        )

        XCTAssertEqual(
            item.pageURL?.absoluteString,
            "https://skills.sh/site/skills.volces.com/ego-browser"
        )
    }

    func testSummaryParserReturnsOnlyFirstSentenceFromSummaryParagraph() throws {
        let html = #"""
        <html><body>
        <div class="uppercase">Summary</div>
        <div><p><strong>Discover and install specialized agent skills from the open ecosystem when users need extended capabilities. This second sentence must not be shown.</strong></p></div>
        <div>SKILL.md</div>
        </body></html>
        """#

        let summary = try SkillsSummaryPageParser().parse(Data(html.utf8))

        XCTAssertEqual(
            summary,
            "Discover and install specialized agent skills from the open ecosystem when users need extended capabilities."
        )
    }

    func testSummaryParserDoesNotSplitAtDomainNameAndDecodesEntities() throws {
        let html = #"""
        <div>Summary</div>
        <section><p>Find skills on skills.sh for design &amp; testing. Ignore this sentence.</p></section>
        <div>SKILL.md</div>
        """#

        let summary = try SkillsSummaryPageParser().parse(Data(html.utf8))

        XCTAssertEqual(summary, "Find skills on skills.sh for design & testing.")
    }

    func testFilterMatchesNameAndSourceCaseInsensitively() {
        let items = fixtureItems()

        let result = SkillsCatalogFilter(query: "OPENAI", category: .all).apply(to: items)

        XCTAssertEqual(result.map(\.slug), ["openai-docs"])
    }

    func testFilterCombinesCategoryAndQuery() {
        let items = fixtureItems()

        let result = SkillsCatalogFilter(query: "ui", category: .design).apply(to: items)

        XCTAssertEqual(result.map(\.slug), ["frontend-design"])
    }

    func testOfficialCategoryUsesCatalogMetadata() {
        let items = fixtureItems()

        let result = SkillsCatalogFilter(query: "", category: .official).apply(to: items)

        XCTAssertEqual(result.map(\.slug), ["openai-docs"])
    }

    func testShortDesignKeywordDoesNotMisclassifyBuildSkill() {
        let item = SkillsCatalogItem(
            source: "example/skills",
            slug: "build-fast-apps",
            name: "Build Fast Apps",
            installs: 10,
            isOfficial: false
        )

        XCTAssertEqual(SkillsCatalogCategory.inferred(for: item), .development)
    }

    func testCachePolicyKeepsFreshSnapshotWithoutRefreshing() {
        let now = Date(timeIntervalSince1970: 20_000)
        let snapshot = SkillsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: now.addingTimeInterval(-(6 * 60 * 60 - 1))
        )

        XCTAssertFalse(SkillsCatalogCachePolicy().shouldRefresh(snapshot, now: now))
    }

    func testCachePolicyRefreshesMissingOrExpiredSnapshot() {
        let now = Date(timeIntervalSince1970: 20_000)
        let expired = SkillsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: now.addingTimeInterval(-(6 * 60 * 60))
        )
        let policy = SkillsCatalogCachePolicy()

        XCTAssertTrue(policy.shouldRefresh(nil, now: now))
        XCTAssertTrue(policy.shouldRefresh(expired, now: now))
    }

    func testDiskCacheRoundTripsSnapshot() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-skills-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = DiskSkillsCatalogCache(fileURL: cacheRoot.appendingPathComponent("snapshot.json"))
        let snapshot = SkillsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: Date(timeIntervalSince1970: 12_345)
        )

        try cache.save(snapshot)

        XCTAssertEqual(try cache.load(), snapshot)
    }

    @MainActor
    func testStoreUsesFreshDiskSnapshotWithoutNetworkRequest() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let snapshot = SkillsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: now.addingTimeInterval(-60)
        )
        let client = StubSkillsFetcher(result: .success([]))
        let cache = MemorySkillsCatalogCache(snapshot: snapshot)
        let store = SkillsCatalogStore(client: client, cache: cache)

        await store.loadIfNeeded(now: now)

        XCTAssertEqual(store.items, snapshot.items)
        XCTAssertEqual(store.lastUpdated, snapshot.fetchedAt)
        XCTAssertTrue(client.requests.isEmpty)
    }

    @MainActor
    func testStoreKeepsExpiredSnapshotWhenBackgroundRefreshFails() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let snapshot = SkillsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: now.addingTimeInterval(-(7 * 60 * 60))
        )
        let client = StubSkillsFetcher(result: .failure(StubSkillsError.offline))
        let store = SkillsCatalogStore(
            client: client,
            cache: MemorySkillsCatalogCache(snapshot: snapshot)
        )

        await store.loadIfNeeded(now: now)

        XCTAssertEqual(store.items, snapshot.items)
        XCTAssertEqual(client.requests, [false])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isInitialLoading)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testStoreLoadsOnceAndManualRefreshBypassesURLCache() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let client = StubSkillsFetcher(result: .success(fixtureItems()))
        let cache = MemorySkillsCatalogCache(snapshot: nil)
        let store = SkillsCatalogStore(client: client, cache: cache)

        await store.loadIfNeeded(now: now)
        await store.loadIfNeeded(now: now.addingTimeInterval(60))
        await store.refresh(now: now.addingTimeInterval(120))

        XCTAssertEqual(client.requests, [false, true])
        XCTAssertEqual(cache.savedSnapshots.count, 2)
        XCTAssertEqual(store.lastUpdated, now.addingTimeInterval(120))
    }

    @MainActor
    func testCancelledInitialLoadCanRetryWhenViewReappears() async {
        let client = SequencedSkillsFetcher(results: [
            .failure(CancellationError()),
            .success(fixtureItems())
        ])
        let store = SkillsCatalogStore(
            client: client,
            cache: MemorySkillsCatalogCache(snapshot: nil)
        )

        await store.loadIfNeeded()
        await store.loadIfNeeded()

        XCTAssertEqual(client.requests, [false, false])
        XCTAssertEqual(store.items, fixtureItems())
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testStoreLoadsEachMissingSummaryOnceAndPersistsIt() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let snapshot = SkillsCatalogSnapshot(items: fixtureItems(), fetchedAt: now)
        let client = StubSkillsFetcher(result: .success([]))
        let summaryClient = StubSkillsSummaryFetcher(
            result: .success("A focused summary from skills.sh.")
        )
        let cache = MemorySkillsCatalogCache(snapshot: snapshot)
        let store = SkillsCatalogStore(
            client: client,
            summaryClient: summaryClient,
            cache: cache
        )

        await store.loadIfNeeded(now: now)
        await store.loadSummary(for: "openai/skills/openai-docs")
        await store.loadSummary(for: "openai/skills/openai-docs")

        XCTAssertEqual(summaryClient.requestedIDs, ["openai/skills/openai-docs"])
        XCTAssertEqual(store.items.first?.summary, "A focused summary from skills.sh.")
        XCTAssertEqual(cache.savedSnapshots.last?.items.first?.summary, "A focused summary from skills.sh.")
    }

    @MainActor
    func testSummarylessSkillIsRememberedInsteadOfRefetched() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let snapshot = SkillsCatalogSnapshot(items: fixtureItems(), fetchedAt: now)
        let summaryClient = StubSkillsSummaryFetcher(
            result: .failure(SkillsCatalogParsingError.noSummary)
        )
        let cache = MemorySkillsCatalogCache(snapshot: snapshot)
        let store = SkillsCatalogStore(
            client: StubSkillsFetcher(result: .success([])),
            summaryClient: summaryClient,
            cache: cache
        )

        await store.loadIfNeeded(now: now)
        await store.loadSummary(for: "openai/skills/openai-docs")
        await store.loadSummary(for: "openai/skills/openai-docs")

        XCTAssertEqual(summaryClient.requestedIDs, ["openai/skills/openai-docs"])
        XCTAssertTrue(store.items.first?.summaryUnavailable ?? false)
        XCTAssertFalse(store.items.first?.needsSummary ?? true)
        XCTAssertTrue(cache.savedSnapshots.last?.items.first?.summaryUnavailable ?? false)
    }

    @MainActor
    func testSummaryFetchingKeepsOnlyAFewPagesOpenAtOnce() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let items = (0..<12).map { index in
            SkillsCatalogItem(
                source: "owner/skills",
                slug: "skill-\(index)",
                name: "Skill \(index)",
                installs: index,
                isOfficial: false
            )
        }
        let summaryClient = ConcurrencyTrackingSummaryFetcher()
        let store = SkillsCatalogStore(
            client: StubSkillsFetcher(result: .success([])),
            summaryClient: summaryClient,
            cache: MemorySkillsCatalogCache(
                snapshot: SkillsCatalogSnapshot(items: items, fetchedAt: now)
            )
        )

        await store.loadIfNeeded(now: now)
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask { @MainActor in
                    await store.loadSummary(for: item.id)
                }
            }
        }

        let peak = await summaryClient.peakConcurrency
        let completed = await summaryClient.completedCount
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(completed, items.count)
        XCTAssertEqual(store.items.filter(\.needsSummary).count, 0)
    }

    func testCatalogItemDecodesSnapshotsWrittenBeforeTheUnavailableFlag() throws {
        let legacy = """
        {"source":"openai/skills","slug":"openai-docs","name":"OpenAI Docs",\
        "installs":3200,"isOfficial":true,"summary":"Existing summary"}
        """

        let item = try JSONDecoder().decode(
            SkillsCatalogItem.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(item.summary, "Existing summary")
        XCTAssertFalse(item.summaryUnavailable)
        XCTAssertFalse(item.needsSummary)
    }

    @MainActor
    func testStoreSearchesRemoteAndReusesNormalizedInMemoryCache() async {
        let remoteItem = SkillsCatalogItem(
            source: "citrolabs/ego-lite",
            slug: "ego-browser",
            name: "ego-browser",
            installs: 3_581,
            isOfficial: false
        )
        let searchClient = StubSkillsSearcher(result: .success([remoteItem]))
        let store = SkillsCatalogStore(
            client: StubSkillsFetcher(result: .success([])),
            searchClient: searchClient,
            cache: MemorySkillsCatalogCache(snapshot: nil)
        )

        await store.search("  EGO-LITE  ")
        await store.search("ego-lite")

        XCTAssertEqual(searchClient.queries, ["ego-lite"])
        XCTAssertEqual(store.searchQuery, "ego-lite")
        XCTAssertEqual(store.searchResults, [remoteItem])
        XCTAssertFalse(store.isSearching)
        XCTAssertNil(store.searchErrorMessage)
    }

    @MainActor
    func testStoreFallsBackToLocalMatchesWhenRemoteSearchFails() async {
        let snapshot = SkillsCatalogSnapshot(
            items: fixtureItems(),
            fetchedAt: Date(timeIntervalSince1970: 20_000)
        )
        let store = SkillsCatalogStore(
            client: StubSkillsFetcher(result: .success([])),
            searchClient: StubSkillsSearcher(result: .failure(StubSkillsError.offline)),
            cache: MemorySkillsCatalogCache(snapshot: snapshot)
        )
        await store.loadIfNeeded(now: snapshot.fetchedAt)

        await store.search("openai")

        XCTAssertEqual(store.searchResults.map(\.slug), ["openai-docs"])
        XCTAssertNotNil(store.searchErrorMessage)
        XCTAssertFalse(store.isSearching)
    }

    @MainActor
    func testSlowerSearchCannotReplaceNewerResults() async {
        let searchClient = DelayedSkillsSearcher()
        let store = SkillsCatalogStore(
            client: StubSkillsFetcher(result: .success([])),
            searchClient: searchClient,
            cache: MemorySkillsCatalogCache(snapshot: nil)
        )

        let olderSearch = Task { await store.search("older") }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await store.search("newer")
        await olderSearch.value

        XCTAssertEqual(store.searchQuery, "newer")
        XCTAssertEqual(store.searchResults.map(\.slug), ["newer"])
    }

    private func modelURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PiWork/Features/Skills/SkillsCatalog.swift")
    }

    private func writeSkill(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func fixtureItems() -> [SkillsCatalogItem] {
        [
            SkillsCatalogItem(
                source: "openai/skills",
                slug: "openai-docs",
                name: "OpenAI Docs",
                installs: 3_200,
                isOfficial: true
            ),
            SkillsCatalogItem(
                source: "pbakaus/impeccable",
                slug: "frontend-design",
                name: "UI frontend design",
                installs: 1_200,
                isOfficial: false
            ),
            SkillsCatalogItem(
                source: "antfu/skills",
                slug: "vitest",
                name: "Vitest",
                installs: 900,
                isOfficial: false
            )
        ]
    }
}

private final class StubSkillsFetcher: SkillsCatalogFetching {
    let result: Result<[SkillsCatalogItem], Error>
    private(set) var requests: [Bool] = []

    init(result: Result<[SkillsCatalogItem], Error>) {
        self.result = result
    }

    func fetchSkills(ignoringCache: Bool) async throws -> [SkillsCatalogItem] {
        requests.append(ignoringCache)
        return try result.get()
    }
}

private final class StubSkillsSummaryFetcher: SkillsSummaryFetching {
    let result: Result<String, Error>
    private(set) var requestedIDs: [String] = []

    init(result: Result<String, Error>) {
        self.result = result
    }

    func fetchSummary(for item: SkillsCatalogItem) async throws -> String {
        requestedIDs.append(item.id)
        return try result.get()
    }
}

/// Records how many summary requests are open at the same time so the store's
/// gate can be asserted.
private actor ConcurrencyTrackingSummaryFetcher: SkillsSummaryFetching {
    private var active = 0
    private var peak = 0
    private var completed = 0

    var peakConcurrency: Int { peak }
    var completedCount: Int { completed }

    func fetchSummary(for item: SkillsCatalogItem) async throws -> String {
        active += 1
        peak = max(peak, active)
        try? await Task.sleep(nanoseconds: 20_000_000)
        active -= 1
        completed += 1
        return "Summary for \(item.name)"
    }
}

private final class StubSkillsSearcher: SkillsCatalogSearching {
    let result: Result<[SkillsCatalogItem], Error>
    private(set) var queries: [String] = []

    init(result: Result<[SkillsCatalogItem], Error>) {
        self.result = result
    }

    func searchSkills(query: String) async throws -> [SkillsCatalogItem] {
        queries.append(query)
        return try result.get()
    }
}

private final class DelayedSkillsSearcher: SkillsCatalogSearching {
    func searchSkills(query: String) async throws -> [SkillsCatalogItem] {
        if query == "older" {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return [
            SkillsCatalogItem(
                source: "example/skills",
                slug: query,
                name: query,
                installs: 1,
                isOfficial: false
            )
        ]
    }
}

private final class MemorySkillsCatalogCache: SkillsCatalogCaching {
    private(set) var snapshot: SkillsCatalogSnapshot?
    private(set) var savedSnapshots: [SkillsCatalogSnapshot] = []

    init(snapshot: SkillsCatalogSnapshot?) {
        self.snapshot = snapshot
    }

    func load() throws -> SkillsCatalogSnapshot? { snapshot }

    func save(_ snapshot: SkillsCatalogSnapshot) throws {
        self.snapshot = snapshot
        savedSnapshots.append(snapshot)
    }
}

private final class SequencedSkillsFetcher: SkillsCatalogFetching {
    private var results: [Result<[SkillsCatalogItem], Error>]
    private(set) var requests: [Bool] = []

    init(results: [Result<[SkillsCatalogItem], Error>]) {
        self.results = results
    }

    func fetchSkills(ignoringCache: Bool) async throws -> [SkillsCatalogItem] {
        requests.append(ignoringCache)
        return try results.removeFirst().get()
    }
}

private enum StubSkillsError: Error {
    case offline
}

private final class RecycledURLsRecorder {
    var urls: [URL] = []
}

private final class SequencedInstalledSkillsScanner: InstalledSkillsScanning {
    private var results: [[InstalledSkill]]
    private(set) var scanCount = 0

    init(results: [[InstalledSkill]]) {
        self.results = results
    }

    func scan() throws -> [InstalledSkill] {
        scanCount += 1
        return results.removeFirst()
    }
}

private final class StubInstalledSkillRemover: InstalledSkillRemoving {
    private(set) var removedSkills: [InstalledSkill] = []

    func remove(_ skill: InstalledSkill) async throws {
        removedSkills.append(skill)
    }
}

private final class StubSkillsInstaller: SkillsInstalling {
    private(set) var installedItems: [SkillsCatalogItem] = []

    func install(_ item: SkillsCatalogItem) async throws {
        installedItems.append(item)
    }
}

private final class StubInstalledSkillEnablementManager: InstalledSkillEnablementManaging {
    struct Change {
        let enabled: Bool
        let installations: [InstalledSkillInstallation]
    }

    private(set) var changes: [Change] = []

    func disabledPatterns() throws -> [InstalledSkillSource: Set<String>] { [:] }

    func isEnabled(_ installation: InstalledSkillInstallation) throws -> Bool {
        installation.isEnabled
    }

    func setEnabled(
        _ enabled: Bool,
        for installations: [InstalledSkillInstallation]
    ) throws {
        changes.append(Change(enabled: enabled, installations: installations))
    }
}

private final class InstalledSkillOperationEvents {
    var values: [String] = []
}

private final class OrderedInstalledSkillEnablementManager: InstalledSkillEnablementManaging {
    let events: InstalledSkillOperationEvents

    init(events: InstalledSkillOperationEvents) {
        self.events = events
    }

    func disabledPatterns() throws -> [InstalledSkillSource: Set<String>] { [:] }

    func isEnabled(_ installation: InstalledSkillInstallation) throws -> Bool {
        installation.isEnabled
    }

    func setEnabled(
        _ enabled: Bool,
        for installations: [InstalledSkillInstallation]
    ) throws {
        events.values.append(enabled ? "enable" : "disable")
    }
}

private final class OrderedInstalledSkillRemover: InstalledSkillRemoving {
    let events: InstalledSkillOperationEvents

    init(events: InstalledSkillOperationEvents) {
        self.events = events
    }

    func remove(_ skill: InstalledSkill) async throws {
        events.values.append("remove")
    }
}
