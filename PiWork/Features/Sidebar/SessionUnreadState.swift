import Foundation

/// Tracks sessions that finished while their conversation was not on screen.
///
/// Activity comes from `SessionRecordRunState.showsSidebarActivity`; a session
/// earns an unread dot only when it leaves the active states. That keeps a
/// background or scheduled turn visible as work in progress, then leaves a
/// single dot until the session is opened again.
struct SessionUnreadState: Equatable {
    private(set) var unreadSessionIDs: Set<String> = []
    private var activeSessionIDs: Set<String> = []

    /// Reconcile against the latest store snapshot. `visibleSessionID` is the
    /// conversation currently rendered in the detail column, if any.
    mutating func update(activeSessionIDs: Set<String>, visibleSessionID: String?) {
        let completedSessionIDs = self.activeSessionIDs.subtracting(activeSessionIDs)
        unreadSessionIDs.formUnion(completedSessionIDs)
        unreadSessionIDs.subtract(activeSessionIDs)
        if let visibleSessionID {
            unreadSessionIDs.remove(visibleSessionID)
        }
        self.activeSessionIDs = activeSessionIDs
    }

    mutating func markViewed(_ sessionID: String) {
        unreadSessionIDs.remove(sessionID)
    }

    mutating func remove(_ sessionID: String) {
        unreadSessionIDs.remove(sessionID)
        activeSessionIDs.remove(sessionID)
    }
}
