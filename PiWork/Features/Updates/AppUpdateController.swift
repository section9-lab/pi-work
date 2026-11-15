import AppKit
import Combine
import Sparkle

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading(progress: Double?)
    case extracting(progress: Double?)
    case readyToInstall
    case installing
    case failed
}

/// Automatic checks follow the local working day instead of one fixed interval:
/// every 10 minutes between 09:00 and 19:00 local time, hourly otherwise.
///
/// Sparkle cannot express that alone: `updateCheckInterval` is clamped to
/// `SPUUpdaterSettings.minimumUpdateCheckInterval`, which is 3600 s in release
/// builds. Sparkle therefore keeps its own hourly floor, and the controller
/// drives the frequent checks with `checkForUpdatesInBackground()`.
struct AppUpdateCheckSchedule {
    /// Local hours that count as working time (10 hours).
    static let workingHours: Range<Int> = 9..<19
    static let activeInterval: TimeInterval = 10 * 60
    static let idleInterval: TimeInterval = 60 * 60

    let calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func isWithinWorkingHours(_ date: Date) -> Bool {
        Self.workingHours.contains(calendar.component(.hour, from: date))
    }

    /// Delay until the next check. A boundary shortens the delay so the cadence
    /// switches at 09:00 and 19:00 instead of one interval later.
    func delay(after date: Date) -> TimeInterval {
        let interval = isWithinWorkingHours(date) ? Self.activeInterval : Self.idleInterval
        guard let boundary = nextBoundary(after: date) else { return interval }
        return min(interval, max(1, boundary.timeIntervalSince(date)))
    }

    private func nextBoundary(after date: Date) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        var candidates: [Date] = []
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else {
                continue
            }
            for hour in [Self.workingHours.lowerBound, Self.workingHours.upperBound] {
                guard let candidate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                      candidate > date else { continue }
                candidates.append(candidate)
            }
        }
        return candidates.min()
    }
}

/// Sparkle owns scheduling, signature verification, installation and relaunch.
/// This driver keeps consent and progress in the application's existing UI.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    @Published private(set) var state = AppUpdateState.idle
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var canCancel = false
    @Published private(set) var canRetryRelaunch = false
    @Published private(set) var failureDescription = ""
    @Published private(set) var isFailureSilent = false
    @Published private(set) var hasActiveTasks = false
    let currentVersion: String

    private let bundle: Bundle
    private let architecture: AppArchitecture
    private let configuredFeedURL: URL?
    private var updater: SPUUpdater?
    private var updateChoice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var authorizedInstallation = false
    private var manualCheck = false
    private var receivedBytes: UInt64 = 0
    private var expectedBytes: UInt64 = 0
    private var retryRelaunch: (() -> Void)?
    private var preparedInstallation: (() -> Void)?
    private var taskActivityObservation: AnyCancellable?
    private var currentTaskActivity: () -> Bool = { false }
    private let checkSchedule = AppUpdateCheckSchedule()
    private var automaticCheckTimer: Timer?
    private var scheduleObservers: [NSObjectProtocol] = []

    init(bundle: Bundle = .main, architecture: AppArchitecture = .current, feedURL: URL? = nil) {
        self.bundle = bundle
        self.architecture = architecture
        configuredFeedURL = feedURL
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        super.init()
    }

    var isChecking: Bool { state == .checking }
    var isInstalling: Bool {
        switch state {
        case .downloading, .extracting, .readyToInstall, .installing: return true
        default: return false
        }
    }
    // Read the source again at every consequential action, including Sparkle's
    // relaunch callback. The published value also keeps all update surfaces current.
    private var tasksPreventInstallation: Bool { currentTaskActivity() }

    var installationHelp: String {
        hasActiveTasks ? L10n.string("update.tasks_running") : statusDescription
    }

    func observeTaskActivity(_ activity: AnyPublisher<Bool, Never>, current: @escaping () -> Bool) {
        currentTaskActivity = current
        hasActiveTasks = current()
        taskActivityObservation = activity.removeDuplicates().sink { [weak self] active in
            self?.hasActiveTasks = active
        }
    }

    var statusDescription: String {
        switch state {
        case .idle: return L10n.format("update.installed_version", currentVersion)
        case .checking: return L10n.string("update.checking")
        case .upToDate: return L10n.format("update.status.up_to_date", currentVersion)
        case let .available(version): return L10n.format("update.status.available", version)
        case .downloading: return L10n.string("update.downloading")
        case .extracting: return L10n.string("update.extracting")
        case .readyToInstall: return L10n.string("update.ready_to_restart")
        case .installing: return L10n.string("update.installing")
        case .failed: return failureDescription
        }
    }

    func start() {
        guard updater == nil else { return }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        do {
            // Checking is automatic; downloading always requires an explicit click,
            // including when an older installation saved different Sparkle preferences.
            updater.automaticallyDownloadsUpdates = false
            // Sparkle's lower bound; the frequent working-hours cadence is
            // scheduled by `scheduleAutomaticCheck()`.
            updater.updateCheckInterval = AppUpdateCheckSchedule.idleInterval
            try updater.start()
            self.updater = updater
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
            observeScheduleEnvironment()
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
            scheduleAutomaticCheck()
        } catch { fail(error) }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
        scheduleAutomaticCheck()
    }

    /// Re-evaluate the cadence when the clock, time zone or wake state changes;
    /// a timer that was armed for the old working day is no longer correct.
    private func observeScheduleEnvironment() {
        guard scheduleObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        scheduleObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleAutomaticCheck() }
        })
        for name in [Notification.Name.NSSystemTimeZoneDidChange, Notification.Name.NSSystemClockDidChange] {
            scheduleObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleAutomaticCheck() }
            })
        }
    }

    private func scheduleAutomaticCheck() {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        guard let updater, updater.automaticallyChecksForUpdates else { return }
        let delay = checkSchedule.delay(after: Date())
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.automaticCheckFired() }
        }
        timer.tolerance = min(60, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        automaticCheckTimer = timer
    }

    private func automaticCheckFired() {
        guard let updater, updater.automaticallyChecksForUpdates else { return }
        updater.checkForUpdatesInBackground()
        scheduleAutomaticCheck()
    }

    func checkForUpdatesAndPresent() {
        start()
        guard let updater, !isInstalling else { return }
        manualCheck = true
        updater.checkForUpdates()
    }

    func installAvailableUpdate() {
        guard !tasksPreventInstallation, case .available = state, let reply = updateChoice else { return }
        authorizedInstallation = true
        updateChoice = nil
        state = .downloading(progress: nil)
        reply(.install)
    }

    func cancel() {
        guard canCancel else { return }
        let cancel = cancellation
        cancellation = nil
        canCancel = false
        authorizedInstallation = false
        state = .idle
        cancel?()
    }

    func dismissOffer() {
        let reply = updateChoice
        updateChoice = nil
        state = .idle
        reply?(.dismiss)
    }

    func installPreparedUpdate() {
        guard !tasksPreventInstallation, state == .readyToInstall, let install = preparedInstallation else { return }
        preparedInstallation = nil
        state = .installing
        install()
    }

    func retryInstallationRelaunch() {
        guard !tasksPreventInstallation else { return }
        retryRelaunch?()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunchIfNeeded(installHandler)
    }

    func postponeRelaunchIfNeeded(_ install: @escaping () -> Void) -> Bool {
        guard tasksPreventInstallation else { return false }
        authorizedInstallation = false
        updateChoice = nil
        preparedInstallation = install
        retryRelaunch = nil
        canRetryRelaunch = false
        state = .readyToInstall
        return true
    }

    static func feedURL(architecture: AppArchitecture) -> URL {
        URL(string: "https://github.com/section9-lab/pi-work/releases/latest/download/appcast-\(architecture.rawValue).xml")!
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        (configuredFeedURL ?? Self.feedURL(architecture: architecture)).absoluteString
    }

    // Kept separate from Sparkle's opaque update-state object for lifecycle checks.
    func offerUpdate(version: String, stage: SPUUserUpdateStage = .notDownloaded,
                     reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        canCancel = false
        authorizedInstallation = false
        if stage == .installing {
            updateChoice = nil
            preparedInstallation = { reply(.install) }
            self.state = .readyToInstall
        } else {
            preparedInstallation = nil
            updateChoice = reply
            self.state = .available(version: version)
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        canCancel = true
        state = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate else {
            reply(.dismiss)
            fail(NSError(domain: "PiWork.Update", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: L10n.string("update.error.asset")]))
            return
        }
        offerUpdate(version: appcastItem.displayVersionString, stage: state.stage, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        guard reason?.intValue == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
                || reason?.intValue == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) else {
            fail(error)
            acknowledgement()
            return
        }
        state = .upToDate
        if manualCheck {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.string("update.alert.up_to_date.title")
            alert.informativeText = L10n.format("update.alert.up_to_date.message", currentVersion)
            alert.addButton(withTitle: L10n.string("common.done"))
            alert.runModal()
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        fail(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        canCancel = true
        receivedBytes = 0
        expectedBytes = 0
        state = .downloading(progress: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let sum = receivedBytes.addingReportingOverflow(length)
        receivedBytes = sum.overflow ? .max : sum.partialValue
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        state = .downloading(progress: expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        canCancel = false
        state = .extracting(progress: nil)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        state = .extracting(progress: progress.isFinite ? min(1, max(0, progress)) : nil)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard authorizedInstallation else { reply(.skip); return }
        authorizedInstallation = false
        preparedInstallation = { reply(.install) }
        state = .readyToInstall
        // Sparkle sends a normal quit event. The Host cleans up on stdin EOF;
        // keep it available if installation or app termination is cancelled.
        // A task started during the download requires another explicit click,
        // even after that task finishes. Never queue a restart for idle time.
        installPreparedUpdate()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                             retryTerminatingApplication: @escaping () -> Void) {
        state = .installing
        retryRelaunch = applicationTerminated ? nil : retryTerminatingApplication
        canRetryRelaunch = !applicationTerminated
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        updateChoice = nil
        cancellation = nil
        canCancel = false
        authorizedInstallation = false
        retryRelaunch = nil
        preparedInstallation = nil
        canRetryRelaunch = false
        manualCheck = false
        if isChecking || isInstalling { state = .idle }
    }

    private func fail(_ error: Error) {
        isFailureSilent = !manualCheck && !authorizedInstallation && !isInstalling
        authorizedInstallation = false
        cancellation = nil
        canCancel = false
        preparedInstallation = nil
        retryRelaunch = nil
        canRetryRelaunch = false
        failureDescription = error.localizedDescription
        state = .failed
    }
}
