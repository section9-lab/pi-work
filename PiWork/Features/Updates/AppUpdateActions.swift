import SwiftUI

struct AppUpdateAccountRow<Account: View>: View {
    var controller: AppUpdateController?
    @ViewBuilder var account: () -> Account

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let controller {
                AppUpdateSidebarAccessory(controller: controller)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            account().frame(maxWidth: .infinity)
        }
    }
}

/// Kept outside the account button so an update never opens the account popover.
struct AppUpdateSidebarAccessory: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        Group {
            switch controller.state {
            case .idle, .upToDate, .checking:
                EmptyView()
            case .available:
                AppUpdateInstallButton(controller: controller, titleKey: "update.install")
            case .readyToInstall:
                AppUpdateInstallButton(controller: controller, titleKey: "update.restart")
            case .installing where controller.canRetryRelaunch:
                AppUpdateInstallButton(controller: controller, titleKey: "update.restart")
            case .downloading, .extracting, .installing:
                HStack(spacing: 6) {
                    AppUpdateProgress(controller: controller)
                    Text(progressLabel).font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .help(controller.statusDescription)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(controller.statusDescription)
            case .failed where controller.isFailureSilent:
                EmptyView()
            case .failed:
                Button { controller.checkForUpdatesAndPresent() } label: {
                    Text(L10n.string("common.retry"))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                    .help(controller.failureDescription)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .buttonStyle(RoundedInteractionButtonStyle(baseFill: AppPalette.selectedRowFill))
        .accessibilityIdentifier("sidebar-app-update")
    }

    private var progressLabel: String {
        switch controller.state {
        case let .downloading(progress):
            if let progress { return "\(Int(progress * 100))%" }
            return L10n.string("update.sidebar.downloading")
        case .extracting: return L10n.string("update.sidebar.preparing")
        case .installing: return L10n.string("update.sidebar.restarting")
        default: return L10n.string("update.sidebar.checking")
        }
    }
}

private struct AppUpdateInstallButton: View {
    @ObservedObject var controller: AppUpdateController
    let titleKey: String

    private var title: String {
        if case let .available(version) = controller.state {
            return L10n.format("update.install_version", version)
        }
        return L10n.string(titleKey)
    }

    var body: some View {
        Button {
            switch controller.state {
            case .available: controller.installAvailableUpdate()
            case .readyToInstall: controller.installPreparedUpdate()
            case .installing: controller.retryInstallationRelaunch()
            default: break
            }
        } label: {
            Label(title, systemImage: "arrow.up.circle")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(controller.hasActiveTasks ? Color.secondary : Color.accentColor)
        }
        // Keep the control hoverable and focusable while blocked. The controller
        // guards pointer, keyboard, Settings, and Sparkle entry points alike.
        .help(controller.installationHelp)
        .accessibilityHint(controller.installationHelp)
        .accessibilityIdentifier("install-app-update")
    }
}

private struct AppUpdateProgress: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        Group {
            switch controller.state {
            case let .downloading(progress?), let .extracting(progress?):
                ProgressView(value: progress).progressViewStyle(.circular)
            default:
                ProgressView()
            }
        }
        .controlSize(.small)
        .accessibilityLabel(controller.statusDescription)
    }
}

struct AppUpdateActions: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        HStack(spacing: 8) {
            switch controller.state {
            case .downloading, .extracting, .checking:
                AppUpdateProgress(controller: controller)
            case .installing:
                AppUpdateProgress(controller: controller)
                if controller.canRetryRelaunch {
                    AppUpdateInstallButton(controller: controller, titleKey: "update.restart")
                }
            case .available:
                AppUpdateInstallButton(controller: controller, titleKey: "update.install")
            case .readyToInstall:
                AppUpdateInstallButton(controller: controller, titleKey: "update.restart")
            case .idle, .upToDate, .failed:
                Button(L10n.string("update.check")) { controller.checkForUpdatesAndPresent() }
                    .disabled(!controller.canCheckForUpdates && controller.state != .failed)
            }
            if controller.canCancel {
                Button(L10n.string("common.cancel")) { controller.cancel() }
            }
        }
    }
}
