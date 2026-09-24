import Foundation
import Combine

@MainActor
final class InstalledExtensionsStore: ObservableObject {
    @Published private(set) var packages: [AgentHostInstalledExtensionPackage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var activePackageIDs: Set<String> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var installationErrors: [String: String] = [:]
    @Published private(set) var updateMessages: [String: String] = [:]
    @Published private(set) var settings: [AgentHostExtensionSettings] = []
    @Published private(set) var isLoadingSettings = false
    @Published private(set) var activeSettingsIDs: Set<String> = []

    private let service: any InstalledExtensionsServicing
    private var hasLoaded = false
    private var hasLoadedSettings = false

    init(service: any InstalledExtensionsServicing) {
        self.service = service
    }

    func load(force: Bool = false) async {
        guard !isLoading, force || !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            packages = try await service.listInstalledExtensions(
                requestID: UUID().uuidString
            )
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ package: AgentHostInstalledExtensionPackage) async {
        guard !isWorking(on: package) else { return }
        updateMessages.removeValue(forKey: package.id)
        let succeeded = await perform(on: package) {
            try await service.updateInstalledExtension(
                source: package.source,
                scope: package.scope,
                requestID: UUID().uuidString
            )
        }
        if succeeded {
            updateMessages[package.id] = L10n.string("settings.extensions.update_finished")
            if hasLoadedSettings { await loadSettings(force: true) }
        }
    }

    func install(source: String) async {
        let packageID = "user:\(source)"
        guard activePackageIDs.insert(packageID).inserted else { return }
        defer { activePackageIDs.remove(packageID) }
        do {
            packages = try await service.installExtension(
                source: source,
                requestID: UUID().uuidString
            )
            hasLoaded = true
            errorMessage = nil
            installationErrors.removeValue(forKey: source)
        } catch {
            errorMessage = error.localizedDescription
            installationErrors[source] = error.localizedDescription
        }
    }

    func setEnabled(
        _ package: AgentHostInstalledExtensionPackage,
        enabled: Bool
    ) async {
        await perform(on: package) {
            try await service.setInstalledExtensionEnabled(
                source: package.source,
                scope: package.scope,
                enabled: enabled,
                requestID: UUID().uuidString
            )
        }
    }

    func remove(_ package: AgentHostInstalledExtensionPackage) async {
        await perform(on: package) {
            try await service.removeInstalledExtension(
                source: package.source,
                scope: package.scope,
                requestID: UUID().uuidString
            )
        }
    }

    func loadSettings(force: Bool = false) async {
        guard !isLoadingSettings, force || !hasLoadedSettings else { return }
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        do {
            settings = try await service.listExtensionSettings(
                requestID: UUID().uuidString
            )
            hasLoadedSettings = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updateSettings(
        _ extensionSettings: AgentHostExtensionSettings,
        changes: [AgentHostExtensionSettingChange]
    ) async -> Bool {
        guard !changes.isEmpty,
              activeSettingsIDs.insert(extensionSettings.id).inserted else {
            return false
        }
        defer { activeSettingsIDs.remove(extensionSettings.id) }
        do {
            let updated = try await service.updateExtensionSettings(
                source: extensionSettings.source,
                scope: extensionSettings.scope,
                changes: changes,
                requestID: UUID().uuidString
            )
            if let index = settings.firstIndex(where: { $0.id == updated.id }) {
                settings[index] = updated
            } else {
                settings.append(updated)
                settings.sort { $0.source.localizedStandardCompare($1.source) == .orderedAscending }
            }
            hasLoadedSettings = true
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func settings(for package: AgentHostInstalledExtensionPackage)
        -> AgentHostExtensionSettings? {
        settings.first { $0.id == package.id }
    }

    func isSavingSettings(for extensionSettings: AgentHostExtensionSettings) -> Bool {
        activeSettingsIDs.contains(extensionSettings.id)
    }

    func isWorking(on package: AgentHostInstalledExtensionPackage) -> Bool {
        activePackageIDs.contains(package.id)
    }

    func isInstalled(source: String) -> Bool {
        packages.contains { $0.source == source }
    }

    func isWorking(source: String) -> Bool {
        activePackageIDs.contains("user:\(source)")
    }

    func installationError(for source: String) -> String? {
        installationErrors[source]
    }

    @discardableResult
    private func perform(
        on package: AgentHostInstalledExtensionPackage,
        operation: () async throws -> [AgentHostInstalledExtensionPackage]
    ) async -> Bool {
        guard activePackageIDs.insert(package.id).inserted else { return false }
        defer { activePackageIDs.remove(package.id) }
        do {
            packages = try await operation()
            hasLoaded = true
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
