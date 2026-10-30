import AppKit
import Combine
import SwiftUI

/// Isolated fixture for exercising the production Sparkle driver without
/// replacing PiWork, using conversations, or contacting an external service.
@main
@MainActor
struct AppUpdatePreview: App {
    @StateObject private var controller = AppUpdateController(
        feedURL: URL(string: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as! String)
    )
    @State private var taskActivity = CurrentValueSubject<Bool, Never>(false)
    var body: some Scene {
        WindowGroup("PiWork Update QA") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Update QA · " + controller.currentVersion).font(.title2)
                Text(controller.statusDescription)
                AppUpdateAccountRow(controller: controller) {
                    Text("PiWork QA").lineLimit(1)
                }
                .frame(width: 230)
                Toggle("Task running", isOn: Binding(
                    get: { taskActivity.value }, set: { taskActivity.send($0) }
                ))
                Button(L10n.string("update.check")) { controller.checkForUpdatesAndPresent() }
                    .disabled(!controller.canCheckForUpdates)
            }
            .padding()
            .frame(minWidth: 540, minHeight: 240)
            .task {
                controller.observeTaskActivity(taskActivity.eraseToAnyPublisher(), current: { taskActivity.value })
                controller.start()
            }
        }
        .defaultSize(width: 700, height: 320)
    }
}
