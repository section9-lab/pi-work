import AppKit
import SwiftUI

/// Restores the native title-bar interactions that disappear when SwiftUI draws
/// through a hidden title bar: drag to move the window, and double-click to
/// apply the system "title bar double-click" action (zoom / minimize / none).
///
/// Install only over empty top chrome so real controls keep their own hits.
struct WindowTitlebarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowTitlebarDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Marks custom controls that can overlap the hidden titlebar's drag surface.
/// The marker never handles input; it only lets the control underneath receive it.
struct WindowTitlebarControlRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowTitlebarControlView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowTitlebarControlView: NSView {
    private static let controls = NSHashTable<WindowTitlebarControlView>.weakObjects()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.controls.add(self) } else { Self.controls.remove(self) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func contains(_ point: NSPoint, in window: NSWindow) -> Bool {
        controls.allObjects.contains {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor
                && $0.convert($0.bounds, to: nil).contains(point)
        }
    }
}

private final class WindowTitlebarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies hitTest points in the superview's coordinates, not
        // this view's bounds. A nonzero titlebar origin otherwise shifts the
        // exclusion rectangle and lets dragging steal real button clicks.
        if let window, let superview,
           WindowTitlebarControlView.contains(superview.convert(point, to: nil), in: window) {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            performTitlebarDoubleClickAction()
            return
        }

        window?.performDrag(with: event)
    }

    private func performTitlebarDoubleClickAction() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize":
            window.miniaturize(nil)
        case "None":
            break
        default:
            // Matches the system green-button zoom behavior (fill / restore).
            window.zoom(nil)
        }
    }
}
