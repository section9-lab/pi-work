import AppKit
import SwiftUI
import XCTest
@testable import PiWork

@MainActor
final class ToolDetailBlockTests: XCTestCase {
    func testLongBashCommandWrapsAndGrowsWithoutHorizontalOverflow() async throws {
        let command = "cd /tmp/" + String(repeating: "long-project-path/", count: 8) + " && swift test --disable-sandbox"
        let fixture = makeFixture(text: command, wrapping: .enabled)
        defer { fixture.window.close() }
        try await settle(fixture.host)
        let scroll = try XCTUnwrap(firstScrollView(in: fixture.host))
        let document = try XCTUnwrap(scroll.documentView)

        XCTAssertGreaterThan(scroll.frame.height, 50, "A source line must grow to fit its visual lines")
        XCTAssertLessThanOrEqual(scroll.frame.height, 220)
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1)
    }

    func testResizingReflowsLongUnbrokenPaths() async throws {
        let fixture = makeFixture(text: "/tmp/" + String(repeating: "a", count: 130), wrapping: .enabled)
        defer { fixture.window.close() }
        fixture.window.setContentSize(NSSize(width: 900, height: 500))
        try await settle(fixture.host)
        let wideHeight = try XCTUnwrap(firstScrollView(in: fixture.host)).frame.height

        fixture.window.setContentSize(NSSize(width: 280, height: 500))
        try await settle(fixture.host)
        let scroll = try XCTUnwrap(firstScrollView(in: fixture.host))
        XCTAssertGreaterThan(scroll.frame.height, wideHeight)
        XCTAssertLessThanOrEqual(try XCTUnwrap(scroll.documentView).frame.width, scroll.contentView.bounds.width + 1)
    }

    func testStreamingOutputUpdatesHeightAndLongOutputScrollsVertically() async throws {
        let fixture = makeFixture(text: "hello", wrapping: .toggleable)
        defer { fixture.window.close() }
        try await settle(fixture.host)
        let shortHeight = try XCTUnwrap(firstScrollView(in: fixture.host)).frame.height
        XCTAssertLessThan(shortHeight, 45)

        fixture.host.rootView = detailView(text: String(repeating: "output line\n", count: 100), wrapping: .toggleable)
        try await settle(fixture.host)
        let scroll = try XCTUnwrap(firstScrollView(in: fixture.host))
        XCTAssertEqual(scroll.frame.height, 220, accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)

        fixture.host.rootView = detailView(text: "done", wrapping: .toggleable)
        try await settle(fixture.host)
        XCTAssertEqual(try XCTUnwrap(firstScrollView(in: fixture.host)).frame.height, shortHeight, accuracy: 1)
    }

    func testOtherToolsKeepOriginalHorizontalLayout() async throws {
        let fixture = makeFixture(text: String(repeating: "column ", count: 50), wrapping: .disabled)
        defer { fixture.window.close() }
        try await settle(fixture.host)
        let scroll = try XCTUnwrap(firstScrollView(in: fixture.host))
        XCTAssertLessThan(scroll.frame.height, 45)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.width, scroll.contentView.bounds.width)
    }

    private func detailView(text: String, wrapping: ToolDetailWrapping) -> AnyView {
        AnyView(ToolDetailBlock(title: nil, text: text, wrapping: wrapping)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    private func makeFixture(text: String, wrapping: ToolDetailWrapping) -> (window: NSWindow, host: NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: detailView(text: text, wrapping: wrapping))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return (window, host)
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }
}
