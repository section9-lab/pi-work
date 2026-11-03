import AppKit

final class DownHistoryWheel: NSEvent {
    let targetWindow: NSWindow
    let point: NSPoint

    init(window: NSWindow, point: NSPoint) {
        targetWindow = window
        self.point = point
        super.init()
    }

    required init?(coder: NSCoder) { nil }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { -10 }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}

final class HistoryKeyEvent: NSEvent {
    let targetWindow: NSWindow
    let code: UInt16

    init(window: NSWindow, keyCode: UInt16) {
        targetWindow = window
        code = keyCode
        super.init()
    }

    required init?(coder: NSCoder) { nil }
    override var type: NSEvent.EventType { .keyDown }
    override var window: NSWindow? { targetWindow }
    override var keyCode: UInt16 { code }
}
