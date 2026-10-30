import XCTest
import Combine
import Sparkle
@testable import PiWork

@MainActor
final class ScheduleRunnerTests: XCTestCase {
    private var storeURL: URL!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-schedule-runner-\(UUID().uuidString).json")
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
        storeURL = nil
        calendar = nil
        super.tearDown()
    }

    func testPlannerFindsDailyOccurrenceInsideInterval() {
        let task = makeTask(
            recurrence: .daily,
            time: date(2026, 8, 9, 18, 0)
        )
        let planner = SchedulePlanner(calendar: calendar)

        let occurrence = planner.mostRecentOccurrence(
            for: task,
            after: date(2026, 8, 9, 17, 59),
            through: date(2026, 8, 9, 18, 1)
        )

        XCTAssertEqual(occurrence, date(2026, 8, 9, 18, 0))
    }

    func testPlannerSkipsWeekendForWeekdaySchedule() {
        let task = makeTask(
            recurrence: .weekdays,
            time: date(2026, 8, 7, 18, 0)
        )
        let planner = SchedulePlanner(calendar: calendar)

        XCTAssertNil(
            planner.mostRecentOccurrence(
                for: task,
                after: date(2026, 8, 8, 17, 0),
                through: date(2026, 8, 9, 19, 0)
            )
        )
    }

    func testPlannerUsesSelectedWeekdayForWeeklySchedule() {
        let task = makeTask(
            recurrence: .weekly,
            time: date(2026, 8, 9, 9, 30),
            weekday: 2
        )
        let planner = SchedulePlanner(calendar: calendar)

        let occurrence = planner.mostRecentOccurrence(
            for: task,
            after: date(2026, 8, 9, 0, 0),
            through: date(2026, 8, 10, 10, 0)
        )

        XCTAssertEqual(occurrence, date(2026, 8, 10, 9, 30))
    }

    func testDueTaskExecutesAndIsNotRepeatedForSameOccurrence() async throws {
        let store = ScheduleStore(storeURL: storeURL)
        let task = try store.save(
            ScheduleDraft(
                name: "Project analysis",
                instruction: "Analyze the current project.",
                recurrence: .daily,
                time: date(2026, 8, 9, 18, 0),
                projectPath: "/tmp/project"
            )
        )
        let executor = FakeScheduleExecutor()
        let runner = ScheduleRunner(
            store: store,
            executor: executor,
            planner: SchedulePlanner(calendar: calendar)
        )

        runner.runDueTasks(
            after: date(2026, 8, 9, 17, 59),
            through: date(2026, 8, 9, 18, 1)
        )
        try await waitUntil { store.records.first?.status == .completed }
        runner.runDueTasks(
            after: date(2026, 8, 9, 17, 59),
            through: date(2026, 8, 9, 18, 1)
        )
        await Task.yield()

        XCTAssertEqual(executor.executedTaskIDs, [task.id])
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.scheduledAt, date(2026, 8, 9, 18, 0))
        XCTAssertEqual(store.records.first?.sessionID, "scheduled-session")
    }

    func testRunNowExecutesEvenWhenScheduleIsDisabled() async throws {
        let store = ScheduleStore(storeURL: storeURL)
        let task = try store.save(validDraft())
        store.setEnabled(false, for: task.id)
        let executor = FakeScheduleExecutor()
        let runner = ScheduleRunner(store: store, executor: executor)

        runner.runNow(task.id)
        try await waitUntil { store.records.first?.status == .completed }

        XCTAssertEqual(executor.executedTaskIDs, [task.id])
        XCTAssertNil(store.records.first?.scheduledAt)
        XCTAssertEqual(store.records.first?.resultText, "Scheduled task completed.")
    }

    func testUpdateGuardUsesLiveRunsAndDuplicateRunDoesNotClearActivity() async throws {
        let store = ScheduleStore(storeURL: storeURL)
        let task = try store.save(validDraft())
        store.beginRun(for: task.id) // An interrupted run persisted by an earlier launch.
        let runner = ScheduleRunner(store: store, executor: FakeScheduleExecutor())
        let updates = AppUpdateController()
        updates.observeTaskActivity(runner.$runningTaskIDs.map { !$0.isEmpty }.eraseToAnyPublisher(),
                                    current: { !runner.runningTaskIDs.isEmpty })
        var choices: [SPUUserUpdateChoice] = []
        updates.offerUpdate(version: "0.2.0") { choices.append($0) }
        XCTAssertFalse(updates.hasActiveTasks)
        runner.runNow(task.id)
        runner.runNow(task.id)
        XCTAssertEqual(runner.runningTaskIDs, [task.id])
        XCTAssertTrue(updates.hasActiveTasks)
        updates.installAvailableUpdate()
        XCTAssertTrue(choices.isEmpty)
        try await waitUntil { runner.runningTaskIDs.isEmpty }
        XCTAssertTrue(store.records.contains { $0.status == .running })
        XCTAssertFalse(updates.hasActiveTasks)
        XCTAssertTrue(choices.isEmpty, "A completed scheduled task must not queue an update")
        updates.installAvailableUpdate()
        XCTAssertEqual(choices, [.install])
    }

    func testStartedRunnerExecutesWhenClockPassesScheduledTime() async throws {
        let store = ScheduleStore(storeURL: storeURL)
        _ = try store.save(
            ScheduleDraft(
                name: "Project analysis",
                instruction: "Analyze the current project.",
                recurrence: .daily,
                time: date(2026, 8, 9, 18, 0),
                projectPath: "/tmp/project"
            )
        )
        let executor = FakeScheduleExecutor()
        var currentDate = date(2026, 8, 9, 17, 59)
            .addingTimeInterval(59)
        let runner = ScheduleRunner(
            store: store,
            executor: executor,
            planner: SchedulePlanner(calendar: calendar),
            now: { currentDate },
            pollIntervalNanoseconds: 5_000_000
        )

        runner.start()
        currentDate = date(2026, 8, 9, 18, 0).addingTimeInterval(1)
        try await waitUntil { store.records.first?.status == .completed }
        runner.stop()

        XCTAssertEqual(executor.executedTaskIDs.count, 1)
        XCTAssertEqual(store.records.first?.scheduledAt, date(2026, 8, 9, 18, 0))
    }

    func testExecutionFailureIsVisibleInHistory() async throws {
        let store = ScheduleStore(storeURL: storeURL)
        let task = try store.save(validDraft())
        let executor = FakeScheduleExecutor(error: TestError.failed)
        let runner = ScheduleRunner(store: store, executor: executor)

        runner.runNow(task.id)
        try await waitUntil { store.records.first?.status == .failed }

        XCTAssertEqual(store.records.first?.errorMessage, "failed")
    }

    func testKeepAwakeSettingControlsSystemActivity() {
        let store = ScheduleStore(storeURL: storeURL)
        let wakeController = FakeScheduleWakeController()
        let runner = ScheduleRunner(
            store: store,
            executor: FakeScheduleExecutor(),
            wakeController: wakeController
        )

        runner.setKeepAwake(true)
        runner.setKeepAwake(false)

        XCTAssertEqual(wakeController.values, [true, false])
    }

    func testAgentExecutorUsesFallbackFolderAndSafeDefaultAccess() async throws {
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-scheduled-work-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fallback) }
        let client = FakeScheduleSessionClient()
        let executor = ScheduleAgentExecutor(
            sessionClient: client,
            fallbackDirectory: fallback
        )

        let execution = try await executor.execute(makeTask())

        XCTAssertEqual(execution.sessionID, "scheduled-session")
        XCTAssertEqual(execution.resultText, "Scheduled task completed.")
        XCTAssertEqual(client.cwd, fallback.path)
        XCTAssertEqual(client.instruction, "Analyze the current project.")
        XCTAssertEqual(client.accessMode, .readOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallback.path))
    }

    private func validDraft() -> ScheduleDraft {
        ScheduleDraft(
            name: "Project analysis",
            instruction: "Analyze the current project.",
            recurrence: .daily,
            time: date(2026, 8, 9, 18, 0),
            projectPath: "/tmp/project"
        )
    }

    private func makeTask(
        recurrence: ScheduleRecurrence = .daily,
        time: Date? = nil,
        weekday: Int? = nil
    ) -> ScheduledTask {
        ScheduledTask(
            id: UUID(),
            name: "Project analysis",
            instruction: "Analyze the current project.",
            recurrence: recurrence,
            time: time ?? date(2026, 8, 9, 18, 0),
            weekday: weekday,
            projectPath: nil,
            accessMode: nil,
            isEnabled: true,
            createdAt: date(2026, 8, 1, 0, 0),
            updatedAt: date(2026, 8, 1, 0, 0)
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { throw TestError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private final class FakeScheduleExecutor: ScheduleTaskExecuting {
    private(set) var executedTaskIDs: [UUID] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func execute(_ task: ScheduledTask) async throws -> ScheduleTaskExecution {
        executedTaskIDs.append(task.id)
        if let error { throw error }
        return ScheduleTaskExecution(
            sessionID: "scheduled-session",
            resultText: "Scheduled task completed."
        )
    }
}

@MainActor
private final class FakeScheduleWakeController: ScheduleWakeControlling {
    private(set) var values: [Bool] = []

    func setEnabled(_ isEnabled: Bool) {
        values.append(isEnabled)
    }
}

@MainActor
private final class FakeScheduleSessionClient: ScheduleSessionRunning {
    private(set) var cwd: String?
    private(set) var instruction: String?
    private(set) var accessMode: AgentHostAccessMode?

    func runScheduledPrompt(
        cwd: String,
        instruction: String,
        accessMode: AgentHostAccessMode
    ) async throws -> ScheduleTaskExecution {
        self.cwd = cwd
        self.instruction = instruction
        self.accessMode = accessMode
        return ScheduleTaskExecution(
            sessionID: "scheduled-session",
            resultText: "Scheduled task completed."
        )
    }
}

private enum TestError: Error {
    case failed
    case timedOut
}
