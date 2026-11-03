import AppKit
import XCTest
@testable import PiWork

@MainActor
final class TranscriptScrollObserverTests: XCTestCase {
    func testDistancesUseDocumentGeometryWithoutRequiringAScroller() {
        let document = CGRect(x: 0, y: 0, width: 800, height: 2400)
        XCTAssertEqual(TranscriptScrollPresentation.distances(
            documentBounds: document, visibleRect: CGRect(x: 0, y: 0, width: 800, height: 400), isFlipped: true
        ), TranscriptScrollDistances(fromTop: 0, fromBottom: 2000))
        XCTAssertEqual(TranscriptScrollPresentation.distances(
            documentBounds: document, visibleRect: CGRect(x: 0, y: 2000, width: 800, height: 400), isFlipped: false
        ), TranscriptScrollDistances(fromTop: 0, fromBottom: 2000))
        XCTAssertEqual(TranscriptScrollPresentation.distances(
            documentBounds: document, visibleRect: CGRect(x: 0, y: 2000, width: 800, height: 400), isFlipped: true
        ), TranscriptScrollDistances(fromTop: 2000, fromBottom: 0))
    }

    func testPhaseLessMouseWheelLoadsAtTopAndCanRetryWithoutLeavingTop() async throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        var loads = 0
        var userScrolls = 0
        fixture.observer.hasEarlierMessages = true
        fixture.observer.topThreshold = 160
        fixture.observer.onReachTop = { loads += 1 }
        fixture.observer.onUserScroll = { userScrolls += 1 }
        try await Task.sleep(nanoseconds: 40_000_000)

        fixture.scroll.contentView.scroll(to: CGPoint(x: 0, y: 1000))
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        fixture.scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: fixture.scroll.contentView)
        XCTAssertEqual(loads, 0, "Programmatic scrolling must not fetch history")

        let point = fixture.scroll.convert(CGPoint(x: 100, y: 100), to: nil)
        let wheel = TestPhaseLessScrollWheelEvent(window: fixture.window, point: point)
        XCTAssertTrue(wheel.phase.isEmpty)
        XCTAssertNil(fixture.scroll.verticalScroller)
        fixture.observer.handleScrollWheel(wheel)
        XCTAssertEqual(loads, 1, "A normal wheel notch at the top must load history even without a bounds change")
        XCTAssertEqual(userScrolls, 1)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: fixture.scroll.contentView)
        XCTAssertEqual(loads, 1, "Repeated bounds notifications must not duplicate the request")

        fixture.observer.historyLoadRevision += 1
        fixture.observer.handleScrollWheel(wheel)
        XCTAssertEqual(loads, 2, "A completed or failed load must allow a fresh wheel notch to retry")
    }

    func testTrackpadLiveScrollStillLoadsEarlierMessages() async throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        var loads = 0
        fixture.observer.hasEarlierMessages = true
        fixture.observer.topThreshold = 160
        fixture.observer.onReachTop = { loads += 1 }
        try await Task.sleep(nanoseconds: 40_000_000)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        fixture.scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: fixture.scroll.contentView)
        XCTAssertEqual(loads, 1)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: fixture.scroll)
    }

    func testWheelInsideNestedScrollViewDoesNotLoadTranscriptHistory() async throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let nested = NSScrollView(frame: CGRect(x: 300, y: 30, width: 100, height: 180))
        nested.documentView = FlippedHistoryTestDocument(frame: CGRect(x: 0, y: 0, width: 100, height: 1000))
        fixture.scroll.documentView?.addSubview(nested)
        var loads = 0
        var userScrolls = 0
        fixture.observer.hasEarlierMessages = true
        fixture.observer.topThreshold = 160
        fixture.observer.onReachTop = { loads += 1 }
        fixture.observer.onUserScroll = { userScrolls += 1 }
        try await Task.sleep(nanoseconds: 40_000_000)
        fixture.scroll.contentView.scroll(to: .zero)
        let point = nested.convert(CGPoint(x: 50, y: 60), to: nil)
        fixture.observer.handleScrollWheel(TestPhaseLessScrollWheelEvent(window: fixture.window, point: point))
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(userScrolls, 0)
    }

    private func makeFixture() -> (window: NSWindow, scroll: NSScrollView, observer: TranscriptUserScrollObserverView) {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        scroll.hasVerticalScroller = false
        scroll.verticalScroller = nil
        let document = FlippedHistoryTestDocument(frame: CGRect(x: 0, y: 0, width: 800, height: 2400))
        let observer = TranscriptUserScrollObserverView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        document.addSubview(observer)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        return (window, scroll, observer)
    }
}

private final class FlippedHistoryTestDocument: NSView {
    override var isFlipped: Bool { true }
}

final class TestPhaseLessScrollWheelEvent: NSEvent {
    private let targetWindow: NSWindow
    private let point: NSPoint

    init(window: NSWindow, point: NSPoint) {
        targetWindow = window
        self.point = point
        super.init()
    }

    required init?(coder: NSCoder) { return nil }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { 10 }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}
