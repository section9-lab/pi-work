import Foundation
import Combine

enum SchedulePreferences {
    static let keepAwakeKey = "schedule.keepMacAwake"
}

struct SchedulePlanner {
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func mostRecentOccurrence(
        for task: ScheduledTask,
        after start: Date,
        through end: Date
    ) -> Date? {
        guard end > start else { return nil }

        let hour = calendar.component(.hour, from: task.time)
        let minute = calendar.component(.minute, from: task.time)
        let endDay = calendar.startOfDay(for: end)
        let maximumDaysBack = task.recurrence == .daily ? 1 : 7

        for daysBack in 0...maximumDaysBack {
            guard let day = calendar.date(
                byAdding: .day,
                value: -daysBack,
                to: endDay
            ), isScheduledDay(day, for: task),
            let candidate = calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: day,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ) else {
                continue
            }
            if candidate > start, candidate <= end {
                return candidate
            }
        }
        return nil
    }

    private func isScheduledDay(_ date: Date, for task: ScheduledTask) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        switch task.recurrence {
        case .daily:
            return true
        case .weekdays:
            return (2...6).contains(weekday)
        case .weekly:
            let scheduledWeekday = task.weekday
                ?? calendar.component(.weekday, from: task.time)
            return weekday == scheduledWeekday
        }
    }
}

@MainActor
struct ScheduleTaskExecution: Equatable {
    let sessionID: String
    let resultText: String?
}

@MainActor
protocol ScheduleTaskExecuting: AnyObject {
    func execute(_ task: ScheduledTask) async throws -> ScheduleTaskExecution
}

@MainActor
protocol ScheduleSessionRunning: AnyObject {
    func runScheduledPrompt(
        cwd: String,
        instruction: String,
        accessMode: AgentHostAccessMode
    ) async throws -> ScheduleTaskExecution
}

@MainActor
final class ScheduleAgentExecutor: ScheduleTaskExecuting {
    private let sessionClient: any ScheduleSessionRunning
    private let fallbackDirectory: URL

    init(
        sessionClient: any ScheduleSessionRunning,
        fallbackDirectory: URL? = nil
    ) {
        self.sessionClient = sessionClient
        self.fallbackDirectory = fallbackDirectory ?? Self.defaultFallbackDirectory()
    }

    func execute(_ task: ScheduledTask) async throws -> ScheduleTaskExecution {
        let workingDirectory: URL
        if let projectPath = task.projectPath, !projectPath.isEmpty {
            workingDirectory = URL(fileURLWithPath: projectPath, isDirectory: true)
        } else {
            workingDirectory = fallbackDirectory
            try FileManager.default.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
        }
        return try await sessionClient.runScheduledPrompt(
            cwd: workingDirectory.path,
            instruction: task.instruction,
            accessMode: task.unattendedAccessMode
        )
    }

    private static func defaultFallbackDirectory() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("pi-work", isDirectory: true)
        .appendingPathComponent("Scheduled Tasks", isDirectory: true)
    }
}

private enum ScheduleSessionRunError: Error, CustomStringConvertible {
    case sessionClosed
    case failed(String)
    case timedOut

    var description: String {
        switch self {
        case .sessionClosed:
            return "The scheduled session was closed before it finished."
        case .failed(let message):
            return message
        case .timedOut:
            return "The scheduled session timed out."
        }
    }
}

extension SessionStore: ScheduleSessionRunning {
    func runScheduledPrompt(
        cwd: String,
        instruction: String,
        accessMode: AgentHostAccessMode
    ) async throws -> ScheduleTaskExecution {
        let record = try await createDraft(
            cwd: cwd,
            sessionDirectory: nil,
            profile: .work,
            selectSession: false
        )
        try await selectAccessMode(accessMode, sessionId: record.id)
        _ = try await submitPrompt(sessionId: record.id, text: instruction)
        try await waitForScheduledCompletion(sessionID: record.id)
        let resultText: String? = records[record.id]?.transcript.reversed().compactMap { message -> String? in
            guard message.role == .assistant else { return nil }
            let text = PiChatMessage(message: message).copyableText
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }.first
        return ScheduleTaskExecution(sessionID: record.id, resultText: resultText)
    }

    private func waitForScheduledCompletion(
        sessionID: String,
        timeout: TimeInterval = 21_600
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let record = records[sessionID] else {
                throw ScheduleSessionRunError.sessionClosed
            }
            switch record.runState {
            case .idle:
                return
            case .failed:
                throw ScheduleSessionRunError.failed(
                    record.errorMessage ?? "The scheduled session failed."
                )
            case .opening, .submitting, .running, .stopping:
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw ScheduleSessionRunError.timedOut
    }
}

@MainActor
protocol ScheduleWakeControlling: AnyObject {
    func setEnabled(_ isEnabled: Bool)
}

@MainActor
final class ScheduleWakeController: ScheduleWakeControlling {
    private var activity: NSObjectProtocol?

    func setEnabled(_ isEnabled: Bool) {
        if isEnabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
                reason: "Run pi-work schedules on time"
            )
        } else if !isEnabled, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    deinit {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}

@MainActor
final class ScheduleRunner: ObservableObject {
    private let store: ScheduleStore
    private let executor: any ScheduleTaskExecuting
    private let planner: SchedulePlanner
    private let wakeController: any ScheduleWakeControlling
    private let now: () -> Date
    private let pollIntervalNanoseconds: UInt64

    private var pollingTask: Task<Void, Never>?
    private var lastCheck: Date?
    @Published private(set) var runningTaskIDs: Set<UUID> = []

    init(
        store: ScheduleStore,
        executor: any ScheduleTaskExecuting,
        planner: SchedulePlanner = SchedulePlanner(),
        wakeController: (any ScheduleWakeControlling)? = nil,
        now: @escaping () -> Date = Date.init,
        pollIntervalNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.store = store
        self.executor = executor
        self.planner = planner
        self.wakeController = wakeController ?? ScheduleWakeController()
        self.now = now
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func start() {
        guard pollingTask == nil else { return }
        wakeController.setEnabled(
            UserDefaults.standard.bool(forKey: SchedulePreferences.keepAwakeKey)
        )
        let currentDate = now()
        lastCheck = currentDate
        runDueTasks(after: currentDate.addingTimeInterval(-60), through: currentDate)

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                } catch {
                    return
                }
                self.checkForDueTasks()
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        lastCheck = nil
        wakeController.setEnabled(false)
    }

    func setKeepAwake(_ isEnabled: Bool) {
        wakeController.setEnabled(isEnabled)
    }

    func runNow(_ taskID: UUID) {
        guard let task = store.tasks.first(where: { $0.id == taskID }) else { return }
        launch(task, scheduledAt: nil)
    }

    func runDueTasks(after start: Date, through end: Date) {
        guard end > start else { return }
        for task in store.tasks where task.isEnabled {
            guard !runningTaskIDs.contains(task.id),
                  let occurrence = planner.mostRecentOccurrence(
                    for: task,
                    after: start,
                    through: end
                  ),
                  !store.hasRun(task.id, scheduledAt: occurrence) else {
                continue
            }
            launch(task, scheduledAt: occurrence)
        }
    }

    private func checkForDueTasks() {
        let currentDate = now()
        guard let lastCheck, currentDate > lastCheck else {
            self.lastCheck = currentDate
            return
        }
        self.lastCheck = currentDate
        runDueTasks(after: lastCheck, through: currentDate)
    }

    private func launch(_ task: ScheduledTask, scheduledAt: Date?) {
        guard !runningTaskIDs.contains(task.id) else { return }
        runningTaskIDs.insert(task.id)
        guard let record = store.beginRun(
                for: task.id,
                scheduledAt: scheduledAt,
                at: now()
              ) else {
            runningTaskIDs.remove(task.id)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await self.executor.execute(task)
                self.store.completeRun(
                    record.id,
                    sessionID: execution.sessionID,
                    resultText: execution.resultText,
                    at: self.now()
                )
            } catch {
                self.store.failRun(
                    record.id,
                    message: String(describing: error),
                    at: self.now()
                )
            }
            self.runningTaskIDs.remove(task.id)
        }
    }
}
