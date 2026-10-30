import SwiftUI

struct AppUpdateAccountRow<Account: View>: View {
    var controller: AppUpdateController?
    @ViewBuilder var account: () -> Account

    var body: some View {
        HStack(spacing: 4) {
            account().frame(maxWidth: .infinity)
            if let controller {
                AppUpdateSidebarAccessory(controller: controller)
            }
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
                AppUpdateInstallButton(controller: controller, titleKey: "update.install", iconOnly: true)
            case .readyToInstall:
                AppUpdateInstallButton(controller: controller, titleKey: "update.restart", iconOnly: true)
            case .installing where controller.canRetryRelaunch:
                AppUpdateInstallButton(controller: controller, titleKey: "update.restart", iconOnly: true)
            case .downloading, .extracting, .installing:
                AppUpdateProgress(controller: controller)
                .frame(width: 32, height: 32)
                .help(controller.statusDescription)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(controller.statusDescription)
            case .failed where controller.isFailureSilent:
                EmptyView()
            case .failed:
                Button { controller.checkForUpdatesAndPresent() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                    .help(controller.failureDescription)
                    .accessibilityLabel(L10n.string("common.retry"))
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .buttonStyle(RoundedInteractionButtonStyle(baseFill: AppPalette.selectedRowFill))
        .accessibilityIdentifier("sidebar-app-update")
    }

}

private struct AppUpdateInstallButton: View {
    @ObservedObject var controller: AppUpdateController
    let titleKey: String
    var iconOnly = false

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
            Group {
                if iconOnly {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                } else {
                    Label(title, systemImage: "arrow.up.circle")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
            .foregroundStyle(controller.hasActiveTasks ? Color.secondary : Color.accentColor)
        }
        // Keep the control hoverable and focusable while blocked. The controller
        // guards pointer, keyboard, Settings, and Sparkle entry points alike.
        .help(controller.hasActiveTasks ? controller.installationHelp : title)
        .accessibilityLabel(title)
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
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, progress)))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .accessibilityValue("\(Int(progress * 100))%")
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
