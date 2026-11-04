import AppKit
import SwiftUI
import XCTest
@testable import PiWork

@MainActor
final class SettingsSidebarLayoutTests: XCTestCase {
    func testSidebarStaysNarrowAndHasNoBottomInset() async throws {
        for windowWidth in [656.0, 720.0, 1000.0] {
            let fixture = makeFixture(language: .simplifiedChinese, width: windowWidth)
            defer { fixture.window.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            fixture.host.layoutSubtreeIfNeeded()

            let split = try XCTUnwrap(firstDescendant(of: NSSplitView.self, in: fixture.host))
            let outline = try XCTUnwrap(firstDescendant(of: NSOutlineView.self, in: fixture.host))
            let scrollView = try XCTUnwrap(outline.enclosingScrollView)
            XCTAssertEqual(split.subviews[0].frame.width, 156, accuracy: 1)
            XCTAssertEqual(scrollView.frame.height, fixture.host.frame.height, accuracy: 1)
            XCTAssertEqual(outline.numberOfRows, SettingsDestination.allCases.count)
        }
    }

    func testLongLocalizedSidebarTitlesWrapInsteadOfBeingTruncated() async throws {
        for language in [AppLanguage.english, .spanish] {
            let fixture = makeFixture(language: language, width: 720)
            defer { fixture.window.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            fixture.host.layoutSubtreeIfNeeded()

            let outline = try XCTUnwrap(firstDescendant(of: NSOutlineView.self, in: fixture.host))
            let preferencesIndex = try XCTUnwrap(SettingsDestination.allCases.firstIndex(of: .personalPreferences))
            XCTAssertEqual(outline.numberOfRows, SettingsDestination.allCases.count)
            XCTAssertGreaterThan(
                outline.rect(ofRow: preferencesIndex).height,
                outline.rect(ofRow: 0).height,
                "The personal preferences title should wrap in \(language.rawValue)"
            )
        }
    }

    func testSidebarSelectionStillUpdatesNavigation() async throws {
        let selection = SelectionBox()
        let binding = Binding<SettingsDestination?>(
            get: { selection.value },
            set: { selection.value = $0 }
        )
        let fixture = makeFixture(language: .english, width: 720, selection: binding)
        defer { fixture.window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        fixture.host.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(firstDescendant(of: NSOutlineView.self, in: fixture.host))
        let row = try XCTUnwrap(SettingsDestination.allCases.firstIndex(of: .personalPreferences))
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(selection.value, .personalPreferences)
    }

    private func makeFixture(
        language: AppLanguage,
        width: CGFloat,
        selection: Binding<SettingsDestination?> = .constant(.general)
    ) -> (window: NSWindow, host: NSView) {
        let view = HSplitView {
            SettingsSidebar(selection: selection, language: language)
            Color.clear.frame(minWidth: 436, maxWidth: .infinity)
        }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return (window, host)
    }

    private final class SelectionBox {
        var value: SettingsDestination? = .general
    }

    private func firstDescendant<View: NSView>(of type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        return view.subviews.lazy.compactMap { self.firstDescendant(of: type, in: $0) }.first
    }
}
