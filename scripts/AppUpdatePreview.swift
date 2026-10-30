import AppKit
import SwiftUI

/// Isolated fixture for exercising the production Sparkle driver without
/// replacing PiWork, using conversations, or contacting an external service.
@main
@MainActor
struct AppUpdatePreview: App {
    @StateObject private var controller = AppUpdateController(
        feedURL: URL(string: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as! String)
    )
    var body: some Scene {
        WindowGroup("PiWork Update QA") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Update QA · " + controller.currentVersion).font(.title2)
                Text(controller.statusDescription)
                AppUpdateBanner(controller: controller)
                Button(L10n.string("update.check")) { controller.checkForUpdatesAndPresent() }
                    .disabled(!controller.canCheckForUpdates)
            }
            .padding()
            .frame(minWidth: 540, minHeight: 240)
            .task { controller.start() }
        }
        .defaultSize(width: 700, height: 320)
    }
}
