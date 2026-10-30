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
            try updater.start()
            self.updater = updater
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        } catch { fail(error) }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
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
