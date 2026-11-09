import Foundation

/// Whether this Mac may run the native Mermaid renderer.
///
/// The fork we link builds for macOS 13, so this is a product gate rather than
/// a linking constraint: diagrams stay off on Ventura and those transcripts
/// keep their plain code blocks.
enum MermaidAvailability {
    static func isEnabled(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        preference: Bool = true
    ) -> Bool {
        preference && osVersion.majorVersion >= 14
    }

    static var isEnabledOnThisMac: Bool { isEnabled() }
}

/// Source-level decisions with no MermaidKit dependency, so every OS version
/// the app runs on can test them.
enum MermaidSource {
    /// MermaidKit refuses sources above this bound; skip the work up front.
    static let maximumCharacterCount = 50_000

    /// The fence info string, e.g. `mermaid` or `mermaid title="flow"`.
    static func isMermaidFence(_ language: String?) -> Bool {
        guard let token = language?.split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        return token.lowercased() == "mermaid"
    }

    static func isWithinRenderLimits(_ source: String) -> Bool {
        !source.isEmpty && source.count <= maximumCharacterCount
    }

    /// VoiceOver text from MermaidKit's generated description. The generator
    /// keeps literal `<br/>` markers in node names, which read as noise.
    static func accessibilityDescription(_ generated: String) -> String {
        generated
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
