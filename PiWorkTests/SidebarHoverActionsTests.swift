import XCTest
import SwiftUI
@testable import PiWork

final class SidebarHoverActionsTests: XCTestCase {
    func testSidebarTabSelectionAnimatesOnlyTheIndicatorOffset() throws {
        let source = try sidebarSource()
        let header = try XCTUnwrap(
            source.components(separatedBy: "private struct SidebarTabHeader").last?
                .components(separatedBy: "private struct NavRow").first
        )

        XCTAssertTrue(header.contains("GeometryReader"))
        XCTAssertTrue(header.contains(".offset("))
        XCTAssertTrue(header.contains("CGFloat(selectedTab.rawValue) * indicatorWidth"))
        XCTAssertTrue(header.contains(".animation("))
        XCTAssertTrue(header.contains("value: selectedTab"))
        XCTAssertTrue(header.contains("selectedTab = tab"))
        XCTAssertFalse(header.contains("withAnimation("))
        XCTAssertFalse(header.contains(".matchedGeometryEffect("))
    }

    func testSidebarTabSelectionRespectsReduceMotion() throws {
        let source = try sidebarSource()
        let header = try XCTUnwrap(
            source.components(separatedBy: "private struct SidebarTabHeader").last?
                .components(separatedBy: "private struct NavRow").first
        )

        XCTAssertTrue(header.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(header.contains("accessibilityReduceMotion ? nil"))
    }

    func testSidebarTabButtonsDoNotDrawASecondInteractionLayer() throws {
        let source = try sidebarSource()
        let header = try XCTUnwrap(
            source.components(separatedBy: "private struct SidebarTabHeader").last?
                .components(separatedBy: "private struct NavRow").first
        )

        XCTAssertTrue(header.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(header.contains("RoundedInteractionButtonStyle"))
    }

    @MainActor
    func testNativeSidebarBackdropStabilizerHidesOnlyTheOuterBackdrop() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("The floating glass sidebar is only available on macOS 26 or later")
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 328, height: 680))
        let outerBackdrop = NSView(frame: container.bounds)
        let titlebar = NSView(frame: NSRect(x: 0, y: 628, width: 328, height: 52))
        let glass = NSGlassEffectView(frame: NSRect(x: 8, y: 8, width: 320, height: 664))
        let content = NSView(frame: glass.bounds)
        let anchor = NativeSidebarBackdropAnchor(frame: content.bounds)

        content.addSubview(anchor)
        glass.contentView = content
        container.addSubview(titlebar)
        container.addSubview(outerBackdrop)
        container.addSubview(glass)

        anchor.stabilizeBackdrop()

        XCTAssertTrue(outerBackdrop.isHidden)
        XCTAssertFalse(glass.isHidden)
        XCTAssertFalse(titlebar.isHidden)
    }

    func testSidebarKeepsTheNativeGlassBackdropVisible() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Sidebar/Views/SidebarView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(".background(AppPalette.sidebarSurface.ignoresSafeArea())"))
        XCTAssertEqual(source.components(separatedBy: ".scrollContentBackground(.hidden)").count - 1, 2)
    }

    func testSidebarRowsAvoidHoverTrackingDuringSplitViewTransitions() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Sidebar/Views/SidebarView.swift"
            ),
            encoding: .utf8
        )
        let themeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Core/UI/AppTheme.swift"),
            encoding: .utf8
        )

        XCTAssertGreaterThanOrEqual(
            sidebarSource.components(separatedBy: "tracksHover: false").count - 1,
            3
        )
        XCTAssertTrue(themeSource.contains("var tracksHover = true"))
        XCTAssertTrue(themeSource.contains("if tracksHover"))
    }

    func testMainContentAllowsResizingTheSidebarFromItsDefaultWidth() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("NavigationSplitView {"))
        XCTAssertFalse(source.contains("sidebarVisibility"))
        XCTAssertTrue(source.contains(".navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)"))
        XCTAssertFalse(source.contains(".navigationSplitViewStyle(.prominentDetail)"))
        XCTAssertFalse(source.contains(".navigationSplitViewStyle(.balanced)"))
        XCTAssertFalse(source.contains("TrafficLightPositioner"))
        XCTAssertFalse(source.contains("WindowTitlebarDragRegion"))
    }

    func testMainWindowRestoresTitlebarDoubleClickZoom() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/PiWorkApp.swift"),
            encoding: .utf8
        )
        let regionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Core/UI/WindowTitlebarDragRegion.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("WindowTitlebarDragRegion()"))
        XCTAssertTrue(appSource.contains(".frame(height: 52)"))
        XCTAssertTrue(appSource.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertTrue(regionSource.contains("window?.performDrag(with: event)"))
        XCTAssertTrue(regionSource.contains("window.zoom(nil)"))
        XCTAssertTrue(regionSource.contains("AppleActionOnDoubleClick"))
        XCTAssertTrue(regionSource.contains("mouseDownCanMoveWindow"))
    }

    func testMainContentDrawsTheDetailSurfaceWithoutChangingTheWindowBacking() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(".containerBackground("))
        XCTAssertEqual(source.components(separatedBy: "AppBackgroundGradient()").count - 1, 1)
        XCTAssertTrue(source.contains(".background {\n                AppBackgroundGradient()"))
        XCTAssertFalse(source.contains(".backgroundExtensionEffect()"))
    }

    func testMainWindowDefaultsToSlightlyTallerSize() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/PiWorkApp.swift"),
            encoding: .utf8
        )
        let mainScene = try XCTUnwrap(
            source.components(separatedBy: "WindowGroup {").last?
                .components(separatedBy: "Settings {").first
        )

        XCTAssertTrue(mainScene.contains(".defaultSize(width: 900, height: 680)"))
    }

    func testMainWindowUsesUnifiedToolbarCornersWithHiddenTitle() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/PiWorkApp.swift"),
            encoding: .utf8
        )

        let mainScene = try XCTUnwrap(
            source.components(separatedBy: "WindowGroup {").last?
                .components(separatedBy: "Settings {").first
        )

        XCTAssertTrue(source.contains("SidebarCommands()"))
        XCTAssertTrue(mainScene.contains(".windowStyle(.hiddenTitleBar)"))
        XCTAssertTrue(mainScene.contains(".windowToolbarStyle(.unified(showsTitle: false))"))
    }

    func testPersonalPreferencesUsesACompactDocumentEditorWithAlignedPlaceholder() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )
        let preferences = try XCTUnwrap(
            source.components(separatedBy: "private struct GlobalAgentInstructionsSettingsView").last?
                .components(separatedBy: "private struct ExperimentsSettingsView").first
        )

        XCTAssertTrue(preferences.contains("AlignedPlaceholderTextEditor("))
        XCTAssertFalse(preferences.contains("ZStack(alignment: .topLeading)"))
        XCTAssertFalse(preferences.contains(".padding(.horizontal, 15)"))

        XCTAssertTrue(source.contains("textContainer?.lineFragmentPadding = 0"))
        XCTAssertTrue(source.contains("let origin = textContainerOrigin"))
    }

    func testMainWindowDoesNotInstallAnExtraAppKitBackplane() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/PiWorkApp.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("WindowBackdropConfigurator"))
        XCTAssertFalse(source.contains("window.backgroundColor = .windowBackgroundColor"))
    }

    func testSettingsPresentationDismissesPopoverBeforeDeferringWindowOpen() {
        var events: [String] = []
        var deferredOpen: (() -> Void)?

        SettingsPresentationSequencer.present(
            dismiss: { events.append("dismiss") },
            schedule: { deferredOpen = $0 },
            open: { events.append("open") }
        )

        XCTAssertEqual(events, ["dismiss"])

        deferredOpen?()

        XCTAssertEqual(events, ["dismiss", "open"])
    }

    func testProjectDisclosureStartsCollapsed() {
        let projectID = UUID()
        let state = ProjectDisclosureState()

        XCTAssertFalse(state.isExpanded(projectID))
    }

    func testProjectDisclosureTogglesProjectsIndependently() {
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        var state = ProjectDisclosureState()

        state.toggle(firstProjectID)

        XCTAssertTrue(state.isExpanded(firstProjectID))
        XCTAssertFalse(state.isExpanded(secondProjectID))

        state.toggle(firstProjectID)

        XCTAssertFalse(state.isExpanded(firstProjectID))
    }

    func testSecondaryActionIsHiddenWithoutHover() {
        XCTAssertFalse(SidebarHoverActionVisibility(isHovering: false).showsAction)
    }

    func testSecondaryActionAppearsWhileHovering() {
        XCTAssertTrue(SidebarHoverActionVisibility(isHovering: true).showsAction)
    }

    func testRoundedInteractionDistinguishesHoverAndPress() {
        let hovered = RoundedInteractionVisualState(isHovering: true, isPressed: false)
        let pressed = RoundedInteractionVisualState(isHovering: true, isPressed: true)

        XCTAssertEqual(hovered.overlayOpacity, 0.055, accuracy: 0.001)
        XCTAssertEqual(hovered.scale, 1)
        XCTAssertEqual(pressed.overlayOpacity, 0.10, accuracy: 0.001)
        XCTAssertLessThan(pressed.scale, hovered.scale)
    }

    func testSelectedAndHoveredRowsUseSemanticSlateFills() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Core/UI/AppPalette.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("static let selectedRowFill = dynamic("))
        XCTAssertTrue(source.contains("static let hoverRowFill = dynamic("))
    }

    func testAppPaletteMatchesReferencePearlBlueBackdrop() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Core/UI/AppPalette.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("dynamic(light: 0xE0EBFE, dark: 0x2E3F59)"))
        XCTAssertTrue(source.contains("dynamic(light: 0xEEF5FC, dark: 0x29394C)"))
        XCTAssertTrue(source.contains("light: 0x6B84AA, lightAlpha: 0.14"))
        XCTAssertTrue(source.contains("dynamic(light: 0xF9FAFB, dark: 0x30363D)"))
        XCTAssertTrue(source.contains("startPoint: .top"))
        XCTAssertTrue(source.contains("endPoint: .bottom"))
        XCTAssertFalse(source.contains("0x91BCE6"))
        XCTAssertFalse(source.contains("0x7DB3E8"))
    }

    func testPinnedHeaderAndFooterStayOutsideScrollableListWithoutRestyling() throws {
        let source = try sidebarSource()
        let sidebarBody = try XCTUnwrap(
            source.components(separatedBy: "    var body: some View {").dropFirst().first?
                .components(separatedBy: "\n    private func navigationRow").first
        )
        let headerOffset = try XCTUnwrap(sidebarBody.range(of: "SidebarTabHeader(")).lowerBound
        let listOffset = try XCTUnwrap(sidebarBody.range(of: "List(selection:")).lowerBound
        let footerOffset = try XCTUnwrap(sidebarBody.range(of: "UserFooterView()")).lowerBound

        XCTAssertTrue(sidebarBody.contains("VStack(spacing: 0) {"))
        XCTAssertLessThan(headerOffset, listOffset)
        XCTAssertLessThan(listOffset, footerOffset)
        XCTAssertFalse(sidebarBody.contains(".safeAreaInset(edge: .top"))
        XCTAssertFalse(sidebarBody.contains(".safeAreaInset(edge: .bottom"))
        XCTAssertFalse(sidebarBody.contains(".background(.regularMaterial)"))
    }

    func testWorkProjectHeaderStaysOutsideScrollableProjectList() throws {
        let source = try sidebarSource()
        let sidebarBody = try XCTUnwrap(
            source.components(separatedBy: "    var body: some View {").dropFirst().first?
                .components(separatedBy: "\n    private func navigationRow").first
        )
        let workBranch = try XCTUnwrap(
            sidebarBody.components(separatedBy: "            case .work:").last?
                .components(separatedBy: "\n            UserFooterView()").first
        )
        let navigationOffset = try XCTUnwrap(
            workBranch.range(of: "navigationRow(.schedule)")
        ).lowerBound
        let projectHeaderOffset = try XCTUnwrap(
            workBranch.range(of: "LinkedFoldersHeader(onAddFolder: onAddFolder)")
        ).lowerBound
        let projectListOffset = try XCTUnwrap(
            workBranch.range(of: "List {")
        ).lowerBound

        XCTAssertLessThan(navigationOffset, projectHeaderOffset)
        XCTAssertLessThan(projectHeaderOffset, projectListOffset)
        XCTAssertFalse(workBranch.contains("} header: {\n                            LinkedFoldersHeader"))
    }

    func testWorkProjectListDoesNotSelectProjectsWhenFoldersAreToggled() throws {
        let source = try sidebarSource()
        let workBranch = try XCTUnwrap(
            source.components(separatedBy: "            case .work:").last?
                .components(separatedBy: "\n            UserFooterView()").first
        )

        XCTAssertTrue(workBranch.contains("List {"))
        XCTAssertFalse(workBranch.contains("List(selection: $selectedProject)"))
    }

    func testSidebarTabsKeepRaisedWhiteSelectionIndependentFromGrayRows() throws {
        let source = try sidebarSource()

        XCTAssertTrue(source.contains(".fill(AppPalette.raisedSurface)"))
        XCTAssertTrue(source.contains("let indicatorWidth = (geometry.size.width - 6) / 2"))
        XCTAssertTrue(source.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(
            source.contains(
                "RoundedInteractionButtonStyle(cornerRadius: 17, isSelected: isSelected)"
            )
        )
    }

    func testNewActionUsesCompactLabel() throws {
        let source = try sidebarSource()

        XCTAssertTrue(source.contains("title: L10n.string(\"sidebar.new\")"))
        XCTAssertFalse(source.contains("New Session"))
    }

    func testNewActionUsesTransientNavigationInteraction() throws {
        let source = try sidebarSource()
        let newAction = try XCTUnwrap(
            source.components(separatedBy: "title: L10n.string(\"sidebar.new\"),").last?
                .components(separatedBy: ") {").first
        )

        XCTAssertTrue(newAction.contains("isSelected: false"))
        XCTAssertFalse(source.contains("private struct NewSessionRow"))
    }

    func testNewActionAppearsOnlyInChatSidebar() throws {
        let source = try sidebarSource()
        let tabBranches = try XCTUnwrap(
            source.components(separatedBy: "case .chat:").last?
                .components(separatedBy: "case .work:")
        )

        XCTAssertEqual(tabBranches.count, 2)
        XCTAssertTrue(tabBranches[0].contains("L10n.string(\"sidebar.new\")"))
        XCTAssertFalse(tabBranches[1].contains("L10n.string(\"sidebar.new\")"))
    }

    func testWorkNavigationOmitsCustomSectionHeader() throws {
        let source = try sidebarSource()
        let workBranch = try XCTUnwrap(
            source.components(separatedBy: "case .work:").last
        )

        XCTAssertTrue(workBranch.contains("navigationRow(.schedule)"))
        XCTAssertTrue(workBranch.contains("navigationRow(.skills)"))
        XCTAssertTrue(workBranch.contains("navigationRow(.connectedApps)"))
        XCTAssertFalse(
            workBranch.contains("SectionLabel(L10n.string(\"sidebar.custom\"))")
        )
    }

    func testConnectedAppsDestinationUsesExtensionLabel() throws {
        let source = try sidebarSource()

        XCTAssertTrue(
            source.contains(
                "case .connectedApps: return L10n.string(\"sidebar.extensions\")"
            )
        )
        XCTAssertFalse(source.contains("\"关联的应用\""))
    }

    func testLinkedFoldersSectionUsesProjectFolderLabel() throws {
        let source = try sidebarSource()

        XCTAssertTrue(
            source.contains("Text(L10n.string(\"sidebar.project_folders\"))")
        )
        XCTAssertFalse(source.contains("Text(\"已关联的文件夹\")"))
    }

    func testWorkSidebarOmitsTaskRow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Sidebar/Views/SidebarView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NavRow(icon: \"square.and.pencil\", title: \"任务\")"))
    }

    func testWorkSidebarRendersSessionsUnderEachProject() throws {
        let source = try sidebarSource()

        XCTAssertTrue(source.contains("workSessionsByProjectPath[project.path]"))
        XCTAssertTrue(source.contains("WorkSessionRow("))
    }

    func testSidebarActivityIsVisibleWhileSessionExecutionIsInFlight() {
        XCTAssertTrue(SessionRecordRunState.submitting.showsSidebarActivity)
        XCTAssertTrue(SessionRecordRunState.running.showsSidebarActivity)
        XCTAssertTrue(SessionRecordRunState.stopping.showsSidebarActivity)
    }

    func testSidebarActivityIsHiddenOutsideExecution() {
        XCTAssertFalse(SessionRecordRunState.opening.showsSidebarActivity)
        XCTAssertFalse(SessionRecordRunState.idle.showsSidebarActivity)
        XCTAssertFalse(SessionRecordRunState.failed.showsSidebarActivity)
    }

    func testWorkSessionRowUsesNativeActivityIndicatorForActiveSession() throws {
        let source = try sidebarSource()
        let sessionRow = try XCTUnwrap(
            source.components(separatedBy: "private struct WorkSessionRow").last?
                .components(separatedBy: "private struct WorkSessionEmptyState").first
        )

        XCTAssertTrue(source.contains("activeSessionIDs.contains(session.id)"))
        XCTAssertTrue(sessionRow.contains("let showsActivity: Bool"))
        XCTAssertTrue(sessionRow.contains("if showsActivity"))
        XCTAssertTrue(sessionRow.contains("ProgressView()"))
        XCTAssertTrue(sessionRow.contains(".controlSize(.small)"))
    }

    func testWorkProjectsRevealSessionsOrEmptyStateOnlyWhenExpanded() throws {
        let source = try sidebarSource()

        XCTAssertTrue(source.contains("projectDisclosureState.isExpanded(project.id)"))
        XCTAssertTrue(source.contains("if isExpanded"))
        XCTAssertTrue(source.contains("WorkSessionEmptyState()"))
        XCTAssertTrue(source.contains("Text(L10n.string(\"sidebar.no_session\"))"))
    }

    func testWorkSessionContextMenuOffersCopyAndDelete() throws {
        let source = try sidebarSource()
        let sessionRow = try XCTUnwrap(
            source.components(separatedBy: "private struct WorkSessionRow").last?
                .components(separatedBy: "private struct WorkSessionEmptyState").first
        )

        XCTAssertTrue(sessionRow.contains(".sessionContextMenu("))
        XCTAssertTrue(sessionRow.contains("sessionID: session.id"))
        XCTAssertTrue(sessionRow.contains("onDelete: onDelete"))
        XCTAssertTrue(source.contains("L10n.string(\"sidebar.copy_session_id\")"))
        XCTAssertTrue(source.contains("L10n.string(\"sidebar.delete_session\")"))
        XCTAssertTrue(source.contains("NSPasteboard.general"))
        XCTAssertTrue(source.contains("onDeleteWorkSession(project, session)"))
    }

    func testOnlyWorkSessionContextMenuOffersHTMLExport() throws {
        let source = try sidebarSource()
        let workSessionRow = try XCTUnwrap(
            source.components(separatedBy: "private struct WorkSessionRow").last?
                .components(separatedBy: "private struct WorkSessionEmptyState").first
        )
        let chatSessionRow = try XCTUnwrap(
            source.components(separatedBy: "private struct ChatSessionRow").last?
                .components(separatedBy: "private struct FolderRow").first
        )

        XCTAssertTrue(workSessionRow.contains("onExport: onExport"))
        XCTAssertFalse(chatSessionRow.contains("onExport:"))
        XCTAssertTrue(source.contains("L10n.string(\"sidebar.export_html_report\")"))
        XCTAssertTrue(source.contains("onExportWorkSession(project, session)"))
    }

    func testHTMLExportLabelIsLocalizedForEverySupportedLanguage() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for locale in ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"] {
            let strings = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "PiWork/Resources/\(locale).lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            XCTAssertTrue(strings.contains("\"sidebar.export_html_report\""), locale)
        }
    }

    func testContentViewExportsThenOpensTheHTMLReport() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("onExportWorkSession: exportWorkSession"))
        XCTAssertTrue(source.contains("try await sessionStore.exportHTMLReport("))
        XCTAssertTrue(source.contains("NSWorkspace.shared.open(reportURL)"))
    }

    func testChatSessionContextMenuOffersCopyAndDelete() throws {
        let source = try sidebarSource()
        let sessionRow = try XCTUnwrap(
            source.components(separatedBy: "private struct ChatSessionRow").last?
                .components(separatedBy: "private struct FolderRow").first
        )

        XCTAssertTrue(sessionRow.contains("let onDelete: () -> Void"))
        XCTAssertTrue(sessionRow.contains(".sessionContextMenu("))
        XCTAssertTrue(sessionRow.contains("sessionID: session.id"))
        XCTAssertTrue(sessionRow.contains("onDelete: onDelete"))
        XCTAssertTrue(source.contains("onDeleteChatSession(session)"))
    }

    func testSessionContextMenuDoesNotDrawTheDefaultFocusRing() throws {
        let source = try sidebarSource()
        let modifierSource = try XCTUnwrap(
            source.components(separatedBy: "private struct SessionContextMenuModifier").last?
                .components(separatedBy: "private struct SessionContextMenuFocusModifier").first
        )
        let contextMenuRange = try XCTUnwrap(modifierSource.range(of: ".contextMenu {"))
        let focusModifierRange = try XCTUnwrap(
            modifierSource.range(of: ".modifier(SessionContextMenuFocusModifier())")
        )

        XCTAssertLessThan(contextMenuRange.lowerBound, focusModifierRange.lowerBound)
        XCTAssertTrue(source.contains("if #available(macOS 14.0, *)"))
        XCTAssertTrue(source.contains("content.focusEffectDisabled()"))
        XCTAssertTrue(source.contains("content.focusable(false)"))
    }

    func testContentViewDeletesChatSessionsUsingTheChatProfile() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("onDeleteChatSession: deleteChatSession"))
        let deletion = try XCTUnwrap(
            source.components(separatedBy: "private func deleteChatSession(").last?
                .components(separatedBy: "private func deleteWorkSession(").first
        )
        XCTAssertTrue(deletion.contains("sessionStore.deleteSession("))
        XCTAssertTrue(deletion.contains("profile: .chat"))
    }

    func testWorkRowsUseShallowHierarchicalInsets() throws {
        let source = try sidebarSource()
        let folderRow = try XCTUnwrap(
            source.components(separatedBy: "private struct FolderRow").last?
                .components(separatedBy: "private struct WorkSessionRow").first
        )
        let sessionRow = try XCTUnwrap(
            source.components(separatedBy: "private struct WorkSessionRow").last?
                .components(separatedBy: "private struct WorkSessionEmptyState").first
        )

        XCTAssertTrue(folderRow.contains(".padding(.leading, 0)"))
        XCTAssertTrue(sessionRow.contains(".padding(.leading, 12)"))
        XCTAssertTrue(sessionRow.contains(".padding(.leading, 20)"))
        XCTAssertFalse(sessionRow.contains(".padding(.leading, 46)"))
    }

    func testProjectRowOnlyTogglesDisclosureUntilNewSessionIsRequested() throws {
        let source = try sidebarSource()
        let folderRow = try XCTUnwrap(
            source.components(separatedBy: "private struct FolderRow").last?
                .components(separatedBy: "private struct WorkSessionRow").first
        )

        XCTAssertTrue(folderRow.contains(
            "Image(systemName: isExpanded ? \"folder.fill\" : \"folder\")"
        ))
        XCTAssertTrue(folderRow.contains("onToggle()"))
        XCTAssertFalse(folderRow.contains("onSelect()"))
        XCTAssertFalse(source.contains("onSelectWorkProject"))
        XCTAssertTrue(folderRow.contains(".frame(maxWidth: .infinity"))
        XCTAssertFalse(folderRow.contains("chevron.right"))
    }

    func testProjectRowOffersConfirmedRemovalWithoutDeletingTheFolder() throws {
        let source = try sidebarSource()
        let folderRow = try XCTUnwrap(
            source.components(separatedBy: "private struct FolderRow").last?
                .components(separatedBy: "private struct WorkSessionRow").first
        )

        XCTAssertTrue(folderRow.contains(".contextMenu"))
        XCTAssertTrue(folderRow.contains(".confirmationDialog"))
        XCTAssertTrue(folderRow.contains("L10n.string(\"sidebar.remove_project\")"))
        XCTAssertTrue(folderRow.contains("onDelete()"))
        XCTAssertFalse(folderRow.contains("FileManager.default.removeItem"))
    }

    func testContentViewDeletesProjectSessionsBeforeUnlinkingProject() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("onDeleteWorkProject: deleteWorkProject"))
        let deleteSessions = try XCTUnwrap(
            source.range(of: "try await sessionStore.deleteWorkSessions(")
        )
        let unlinkProject = try XCTUnwrap(
            source.range(of: "projectStore.removeProject(project)")
        )
        XCTAssertLessThan(deleteSessions.lowerBound, unlinkProject.lowerBound)
    }

    @MainActor
    func testRemovingProjectKeepsItsFolderOnDisk() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
        let projectFolder = temporaryRoot.appendingPathComponent("kept-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectFolder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = ProjectStore(storeURL: temporaryRoot.appendingPathComponent("projects.json"))
        store.addProject(path: projectFolder.path)
        let project = try XCTUnwrap(store.projects.first)

        store.removeProject(project)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFolder.path))
    }

    func testApplicationChromeOmitsBetaBadges() throws {
        let sidebar = try sidebarSource()
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(sidebar.contains("badge: \"BETA\""))
        XCTAssertFalse(content.contains("BetaBadge()"))
    }

    @MainActor
    func testSidebarTabsStayNearTheWindowToolbar() throws {
        let view = SidebarView(
            projectStore: ProjectStore(),
            selectedProject: .constant(nil),
            selectedTab: .constant(.work),
            onAddFolder: {},
            onNewSession: {},
            onNewProjectSession: { _ in }
        )
        .frame(width: 254, height: 600)
        .background(Color.white)
        .environment(\.colorScheme, .light)

        let bitmap = try TestViewRenderer.render(view, size: CGSize(width: 254, height: 600))
        let topBandHeight = 50
        var darkPixelCount = 0

        for y in 0..<topBandHeight {
            for x in 24..<(bitmap.pixelsWide - 24) {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    color.alphaComponent > 0.5
                else { continue }
                if color.redComponent < 0.45,
                   color.greenComponent < 0.45,
                   color.blueComponent < 0.45 {
                    darkPixelCount += 1
                }
            }
        }

        XCTAssertGreaterThan(
            darkPixelCount,
            0,
            "The Chat and Work tabs should appear in the first 50 points of the sidebar"
        )
    }

    func testStartingProjectSessionSelectsRequestedProject() {
        let project = PiProject(name: "pi-work", path: "/tmp/pi-work")
        var state = WorkSessionSelection()

        state.startNewSession(for: project)

        XCTAssertEqual(state.selectedProject, project)
    }

    func testSelectingSessionTransfersHighlightFromProjectRow() {
        let project = PiProject(name: "pi-work", path: "/tmp/pi-work")
        var state = WorkSessionSelection()

        state.selectProject(project)
        XCTAssertEqual(state.sidebarItem, .project(project.id))

        state.selectSession("session-1", in: project)

        XCTAssertEqual(state.selectedProject, project)
        XCTAssertEqual(
            state.sidebarItem,
            .session(projectID: project.id, sessionID: "session-1")
        )
    }

    func testOnlyLatestSessionOpeningCanCompleteSelection() {
        var state = SessionOpeningState()
        let projectID = UUID()
        let first = state.begin(
            SessionOpeningTarget(
                sessionID: "session-1",
                profile: .work,
                cwd: "/tmp/project",
                projectID: projectID
            )
        )
        let second = state.begin(
            SessionOpeningTarget(
                sessionID: "session-2",
                profile: .work,
                cwd: "/tmp/project",
                projectID: projectID
            )
        )

        XCTAssertFalse(state.complete(first))
        XCTAssertEqual(state.target?.sessionID, "session-2")
        XCTAssertEqual(
            state.pendingWorkSidebarItem,
            .session(projectID: projectID, sessionID: "session-2")
        )
        XCTAssertTrue(state.complete(second))
        XCTAssertNil(state.target)
    }

    func testPendingWorkSessionDoesNotReplaceCommittedSelection() {
        let project = PiProject(name: "pi-work", path: "/tmp/pi-work")
        var committed = WorkSessionSelection()
        committed.selectSession("session-active", in: project)
        var opening = SessionOpeningState()

        opening.begin(
            SessionOpeningTarget(
                sessionID: "session-pending",
                profile: .work,
                cwd: project.path,
                projectID: project.id
            )
        )

        XCTAssertEqual(
            committed.sidebarItem,
            .session(projectID: project.id, sessionID: "session-active")
        )
        XCTAssertEqual(
            opening.pendingWorkSidebarItem,
            .session(projectID: project.id, sessionID: "session-pending")
        )
    }

    func testContentViewCommitsUncachedWorkSelectionOnlyAfterOpenSucceeds() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )
        let openWorkSession = try XCTUnwrap(
            source.components(separatedBy: "private func openWorkSession(").last?
                .components(separatedBy: "private func selectCachedSessionIfAvailable(").first
        )
        let beginOpening = try XCTUnwrap(
            source.components(separatedBy: "private func beginOpeningSession(").last?
                .components(separatedBy: "private func cancelSessionOpening()").first
        )

        XCTAssertFalse(openWorkSession.contains("workSession.selectSession"))
        XCTAssertTrue(beginOpening.contains("commitSessionSelection(for: request.target)"))
    }

    func testSidebarReceivesPendingSelectionWithoutReplacingCommittedSelection() throws {
        let source = try sidebarSource()

        XCTAssertTrue(source.contains("pendingChatSessionId"))
        XCTAssertTrue(source.contains("pendingWorkSidebarItem"))
        XCTAssertTrue(source.contains("showsOpening"))
    }

    func testChangingChatWorkTabCancelsPendingSessionOpening() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/App/Root/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("selectedTab: selectedTabBinding"))
        XCTAssertTrue(source.contains("private var selectedTabBinding: Binding<SidebarTab>"))
        XCTAssertTrue(source.contains("cancelSessionOpening()"))
    }

    func testStartingProjectSessionRenewsSessionIdentity() {
        let oldID = UUID()
        let newID = UUID()
        let project = PiProject(name: "pi-work", path: "/tmp/pi-work")
        var state = WorkSessionSelection(sessionID: oldID)

        state.startNewSession(for: project, sessionID: newID)

        XCTAssertEqual(state.sessionID, newID)
        XCTAssertNotEqual(state.sessionID, oldID)
    }

    private func sidebarSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent("PiWork/Features/Sidebar/Views/SidebarView.swift"),
            encoding: .utf8
        )
    }
}
