import AppKit
import Foundation

/// Observe only input delivered to this application; never record event contents.
@MainActor
final class ForegroundUsageTracker {
    static let shared = ForegroundUsageTracker()
    private var activeObserver: NSObjectProtocol?
    private var inputMonitor: Any?

    func start() {
        guard activeObserver == nil else { return }
        AppAnalytics.shared.start()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppAnalytics.shared.recordActivity() }
        }
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { event in
            Task { @MainActor in
                if NSApplication.shared.isActive { AppAnalytics.shared.recordActivity() }
            }
            return event
        }
        if NSApplication.shared.isActive { AppAnalytics.shared.recordActivity() }
    }
}
