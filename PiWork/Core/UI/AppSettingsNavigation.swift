import Combine
import Foundation

@MainActor
final class AppSettingsNavigation: ObservableObject {
    static let shared = AppSettingsNavigation()
    @Published var selection: SettingsDestination? = .general
}

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case agent
    case computerUse
    case rtk
    case extensions
    case mcp
    case personalPreferences
    case modelsAndAuthentication

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .general:
            return L10n.string("settings.sidebar.general", language: language)
        case .agent:
            return L10n.string("settings.sidebar.agent", language: language)
        case .computerUse:
            return L10n.string("computer_use.title", language: language)
        case .rtk:
            return "RTK"
        case .extensions:
            return L10n.string("settings.sidebar.extensions", language: language)
        case .mcp:
            return "MCP"
        case .personalPreferences:
            return L10n.string("settings.sidebar.personal_preferences", language: language)
        case .modelsAndAuthentication:
            return L10n.string("settings.sidebar.models_auth", language: language)
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .agent: return "slider.horizontal.3"
        case .computerUse: return ""
        case .rtk: return ""
        case .extensions: return "puzzlepiece.extension"
        case .mcp: return ""
        case .personalPreferences: return "person.text.rectangle"
        case .modelsAndAuthentication: return "key.horizontal"
        }
    }
}
