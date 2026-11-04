import Foundation

struct ProjectDisclosureState: Equatable {
    private(set) var expandedProjectIDs: Set<UUID> = []

    func isExpanded(_ projectID: UUID) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    mutating func toggle(_ projectID: UUID) {
        if expandedProjectIDs.contains(projectID) {
            expandedProjectIDs.remove(projectID)
        } else {
            expandedProjectIDs.insert(projectID)
        }
    }
}

/// The store supplies sessions newest-first. Keep a compact list without hiding selection.
struct SidebarSessionList {
    static let collapsedLimit = 5

    let visibleSessions: [AgentHostSessionSummary]
    let hiddenCount: Int
    let canToggle: Bool

    init(sessions: [AgentHostSessionSummary], isExpanded: Bool, selectedSessionID: String?) {
        canToggle = sessions.count > Self.collapsedLimit
        if isExpanded || !canToggle {
            visibleSessions = sessions
        } else {
            var visible = Array(sessions.prefix(Self.collapsedLimit))
            if let selectedSessionID,
               !visible.contains(where: { $0.id == selectedSessionID }),
               let selected = sessions.first(where: { $0.id == selectedSessionID }) {
                // Replace the last preview row, rather than growing the collapsed list.
                visible[visible.count - 1] = selected
            }
            visibleSessions = visible
        }
        hiddenCount = sessions.count - visibleSessions.count
    }
}

struct SidebarHoverActionVisibility {
    let isHovering: Bool

    var showsAction: Bool { isHovering }
}

enum WorkSidebarItem: Equatable {
    case project(UUID)
    case session(projectID: UUID, sessionID: String)
}

struct SessionOpeningTarget: Equatable {
    let sessionID: String
    let profile: AgentHostSessionProfile
    let cwd: String
    let projectID: UUID?

    init(
        sessionID: String,
        profile: AgentHostSessionProfile,
        cwd: String,
        projectID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.profile = profile
        self.cwd = cwd
        self.projectID = projectID
    }
}

struct SessionOpeningRequest: Equatable {
    let id: UUID
    let target: SessionOpeningTarget
}

struct SessionOpeningState: Equatable {
    private(set) var request: SessionOpeningRequest?

    var target: SessionOpeningTarget? { request?.target }

    var pendingChatSessionID: String? {
        target?.profile == .chat ? target?.sessionID : nil
    }

    var pendingWorkSidebarItem: WorkSidebarItem? {
        guard target?.profile == .work,
              let projectID = target?.projectID,
              let sessionID = target?.sessionID else {
            return nil
        }
        return .session(projectID: projectID, sessionID: sessionID)
    }

    @discardableResult
    mutating func begin(_ target: SessionOpeningTarget) -> SessionOpeningRequest {
        let request = SessionOpeningRequest(id: UUID(), target: target)
        self.request = request
        return request
    }

    func isCurrent(_ request: SessionOpeningRequest) -> Bool {
        self.request == request
    }

    @discardableResult
    mutating func complete(_ request: SessionOpeningRequest) -> Bool {
        guard isCurrent(request) else { return false }
        self.request = nil
        return true
    }

    mutating func cancel() {
        request = nil
    }
}

struct WorkSessionSelection: Equatable {
    var selectedProject: PiProject?
    private(set) var sessionID: UUID
    private(set) var sidebarItem: WorkSidebarItem?

    init(
        selectedProject: PiProject? = nil,
        sessionID: UUID = UUID(),
        sidebarItem: WorkSidebarItem? = nil
    ) {
        self.selectedProject = selectedProject
        self.sessionID = sessionID
        self.sidebarItem = sidebarItem
    }

    mutating func startNewSession(
        for project: PiProject? = nil,
        sessionID: UUID = UUID()
    ) {
        selectedProject = project
        self.sessionID = sessionID
        sidebarItem = project.map { .project($0.id) }
    }

    mutating func selectProject(_ project: PiProject) {
        selectedProject = project
        sidebarItem = .project(project.id)
    }

    mutating func selectSession(_ sessionID: String, in project: PiProject) {
        selectedProject = project
        sidebarItem = .session(projectID: project.id, sessionID: sessionID)
    }
}
