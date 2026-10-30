import SwiftUI

struct AppUpdateBanner: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        if controller.showsBanner {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.statusDescription).font(.callout)
                    if case .available = controller.state {
                        Text(L10n.string("update.restart_note"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AppUpdateActions(controller: controller)
                if case .available = controller.state {
                    Button(L10n.string("update.later")) { controller.dismissOffer() }
                } else if case .failed = controller.state {
                    Button(L10n.string("common.done")) { controller.dismissOffer() }
                }
            }
            .padding()
            .background(AppPalette.raisedSurface)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("app-update-banner")
        }
    }
}

struct AppUpdateActions: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        HStack(spacing: 8) {
            switch controller.state {
            case let .downloading(progress), let .extracting(progress):
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                        .accessibilityLabel(controller.statusDescription)
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(controller.statusDescription)
                }
            case .checking, .installing:
                ProgressView().controlSize(.small)
                    .accessibilityLabel(controller.statusDescription)
                if controller.canRetryRelaunch {
                    Button(L10n.string("computer_use.relaunch")) { controller.retryInstallationRelaunch() }
                }
            case .available:
                Button(L10n.string("update.install")) { controller.installAvailableUpdate() }
                    .accessibilityIdentifier("install-app-update")
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
