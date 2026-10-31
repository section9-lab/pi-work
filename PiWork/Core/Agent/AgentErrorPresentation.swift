import SwiftUI

/// A failure as the person using the app should read it: a title that names
/// what broke, one sentence about what it means for the current turn, and an
/// optional next step. Protocol codes and enum dumps stay in `technicalDetail`
/// so they can be inspected on demand instead of being the whole message.
///
/// Only the classification is stored. Copy is resolved through `L10n` at read
/// time, so a notice that is already on screen follows a language change.
struct AgentErrorPresentation: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case upstreamUnreachable
        case authentication
        case rateLimited
        case timeout
        case connectionLost
        case busy
        case internalFailure
        case informational
    }

    let kind: Kind
    let technicalDetail: String?
    /// A message that already carries its own wording: an error the host
    /// reported as text, or a transient notice built from a localized string.
    private let messageOverride: String?
    /// A notice stored as a catalog key so it follows language changes.
    private let messageKey: String?
    private let usesMessageAsDetail: Bool

    var id: String {
        [kind.rawValue, messageKey ?? messageOverride ?? "", technicalDetail ?? ""]
            .joined(separator: "|")
    }

    var title: String {
        if kind == .informational {
            if let messageKey { return L10n.string(messageKey) }
            if let messageOverride { return messageOverride }
        }
        switch kind {
        case .upstreamUnreachable:
            return L10n.string("chat.error.upstream.title")
        case .authentication:
            return L10n.string("chat.error.auth.title")
        case .rateLimited:
            return L10n.string("chat.error.rate_limit.title")
        case .timeout:
            return L10n.string("chat.error.timeout.title")
        case .connectionLost:
            return L10n.string("chat.error.connection.title")
        case .busy:
            return L10n.string("chat.error.busy.title")
        case .internalFailure, .informational:
            return L10n.string("chat.error.internal.title")
        }
    }

    var detail: String? {
        if kind == .informational { return nil }
        switch kind {
        case .upstreamUnreachable:
            return L10n.string("chat.error.upstream.detail")
        case .authentication:
            return L10n.string("chat.error.auth.detail")
        case .rateLimited:
            return L10n.string("chat.error.rate_limit.detail")
        case .timeout:
            return L10n.string("chat.error.timeout.detail")
        case .connectionLost:
            return L10n.string("chat.error.connection.detail")
        case .busy:
            return L10n.string("chat.error.busy.detail")
        case .internalFailure:
            return usesMessageAsDetail
                ? messageOverride
                : L10n.string("chat.error.internal.detail")
        case .informational:
            return nil
        }
    }

    var recovery: String? {
        if kind == .informational || usesMessageAsDetail { return nil }
        switch kind {
        case .upstreamUnreachable:
            return L10n.string("chat.error.upstream.recovery")
        case .authentication:
            return L10n.string("chat.error.auth.recovery")
        case .rateLimited:
            return L10n.string("chat.error.rate_limit.recovery")
        case .timeout:
            return L10n.string("chat.error.timeout.recovery")
        case .connectionLost:
            return L10n.string("chat.error.connection.recovery")
        case .busy:
            return L10n.string("chat.error.busy.recovery")
        case .internalFailure:
            return L10n.string("chat.error.internal.recovery")
        case .informational:
            return nil
        }
    }

    var symbolName: String {
        switch kind {
        case .upstreamUnreachable:
            return "wifi.exclamationmark"
        case .authentication:
            return "key.slash"
        case .rateLimited:
            return "hourglass"
        case .timeout:
            return "clock.badge.exclamationmark"
        case .connectionLost:
            return "bolt.horizontal.circle"
        case .busy:
            return "hourglass.badge.plus"
        case .internalFailure:
            return "exclamationmark.triangle"
        case .informational:
            return "info.circle"
        }
    }

    /// Failures use red; the neutral "just so you know" notices keep the
    /// orange treatment the rest of the app uses for advisories.
    var accentColor: Color {
        kind == .informational ? Color.orange : Color.red
    }

    init(informational message: String) {
        kind = .informational
        technicalDetail = nil
        messageOverride = message
        messageKey = nil
        usesMessageAsDetail = false
    }

    /// Same as `init(informational:)` but keeps the key so the notice is
    /// re-resolved when the language changes.
    init(informationalKey key: String) {
        kind = .informational
        technicalDetail = nil
        messageOverride = nil
        messageKey = key
        usesMessageAsDetail = false
    }

    /// Used for failures that already reached us as text: subscription events,
    /// or history restored from a session written by an earlier build.
    init(rawMessage: String) {
        let signal = AgentErrorPresentation.signal(fromStored: rawMessage)
        let kind = AgentErrorPresentation.classify(signal)
        // A plain sentence from the host already reads like a message; keep its
        // wording instead of replacing it with the generic copy.
        let keepsWording = kind == .internalFailure
            && !signal.isProtocolDump
            && !signal.message.isEmpty
        self.kind = kind
        technicalDetail = keepsWording ? nil : signal.technical
        messageOverride = keepsWording ? signal.message : nil
        messageKey = nil
        usesMessageAsDetail = keepsWording
    }

    init(_ error: Error) {
        let signal = AgentErrorPresentation.signal(for: error)
        let kind = AgentErrorPresentation.classify(signal)
        let override = kind == .internalFailure ? error.presentableDescription : nil
        self.kind = kind
        technicalDetail = signal.technical
        messageOverride = override
        messageKey = nil
        usesMessageAsDetail = override != nil
    }
}

// MARK: - Classification

extension AgentErrorPresentation {
    /// What the error said, split into the parts worth matching on.
    private struct FailureSignal {
        var code: String?
        var message: String
        /// True when the text came from a Swift enum dump rather than prose.
        var isProtocolDump = false

        var technical: String? {
            let trimmedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedMessage.isEmpty else {
                return trimmedCode.isEmpty ? nil : trimmedCode
            }
            guard !trimmedCode.isEmpty else { return trimmedMessage }
            return "\(trimmedCode)\n\(trimmedMessage)"
        }
    }

    private static func signal(for error: Error) -> FailureSignal {
        if let clientError = error as? AgentHostClientError {
            switch clientError {
            case .requestFailed(let code, let message):
                return FailureSignal(code: code, message: message)
            case .requestTimedOut(let requestId):
                return FailureSignal(code: "request_timed_out", message: requestId)
            case .processExited(let status):
                return FailureSignal(code: "process_exited", message: "Agent Host exited with status \(status).")
            case .notRunning:
                return FailureSignal(code: "host_not_running", message: "host_not_running")
            case .alreadyRunning:
                return FailureSignal(code: "host_already_running", message: "host_already_running")
            case .invalidHandshake, .handshakeTimedOut:
                return FailureSignal(code: "host_handshake_failed", message: "host_handshake_failed")
            case .duplicateRequestID(let id):
                return FailureSignal(code: "duplicate_request", message: id)
            case .missingResponseResult:
                return FailureSignal(code: "missing_result", message: "missing_result")
            }
        }

        if let storeError = error as? SessionStoreError {
            switch storeError {
            case .sessionBusy:
                return FailureSignal(code: "session_busy", message: "session_busy")
            case .sessionNotOpen(let sessionId):
                return FailureSignal(code: "session_not_open", message: sessionId)
            case .historyChanged:
                return FailureSignal(code: "history_changed", message: "history_changed")
            case .downloadsDirectoryUnavailable:
                return FailureSignal(code: "downloads_unavailable", message: "downloads_unavailable")
            case .exportedReportMismatch, .exportedReportMissing, .cannotOpenExportedReport:
                return FailureSignal(code: nil, message: String(describing: storeError))
            }
        }

        if let urlError = error as? URLError {
            return FailureSignal(
                code: "url_error_\(urlError.errorCode)",
                message: urlError.localizedDescription
            )
        }

        return FailureSignal(code: nil, message: String(describing: error))
    }

    /// Failures that were persisted as text. Older builds stored the Swift enum
    /// dump (`requestFailed(code: "…", message: "…")`), so unwrap that shape
    /// before matching.
    private static func signal(fromStored raw: String) -> FailureSignal {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let unwrapped = unwrapRequestFailedDump(trimmed) { return unwrapped }
        return FailureSignal(code: nil, message: trimmed)
    }

    private static func unwrapRequestFailedDump(_ raw: String) -> FailureSignal? {
        let prefix = "requestFailed(code: \""
        let separator = "\", message: \""
        guard raw.hasPrefix(prefix) else { return nil }
        let remainder = raw.dropFirst(prefix.count)
        guard let separatorRange = remainder.range(of: separator) else { return nil }
        let code = String(remainder[remainder.startIndex..<separatorRange.lowerBound])
        let tail = remainder[separatorRange.upperBound...]
        guard tail.hasSuffix("\")") else { return nil }
        let message = String(tail.dropLast(2)).unescapingStringDump()
        return FailureSignal(code: code, message: message, isProtocolDump: true)
    }

    private static func classify(_ signal: FailureSignal) -> Kind {
        let code = signal.code?.lowercased() ?? ""
        let message = signal.message.lowercased()
        let haystack = code + " " + message

        if contains(haystack, Self.connectionLostHints) { return .connectionLost }
        if contains(haystack, Self.authenticationHints) { return .authentication }
        if contains(haystack, Self.rateLimitHints) { return .rateLimited }
        if contains(haystack, Self.timeoutHints) { return .timeout }
        if contains(haystack, Self.busyHints) { return .busy }
        if contains(haystack, Self.unreachableHints) { return .upstreamUnreachable }
        return .internalFailure
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static let connectionLostHints = [
        "process_exited", "host_not_running", "host_handshake", "agent host exited",
        "host is not running", "broken pipe", "connection reset by peer",
    ]

    private static let authenticationHints = [
        "unauthorized", "unauthenticated", "authentication", "invalid_api_key",
        "incorrect api key", "invalid api key", "api key", "credential", "401 ", " 401", "403 ",
    ]

    private static let rateLimitHints = [
        "rate limit", "rate_limit", "too many requests", "429", "quota", "overloaded",
    ]

    private static let timeoutHints = [
        "timed out", "timeout", "etimedout", "deadline exceeded",
    ]

    private static let busyHints = [
        "session_busy", "still running", "already running",
    ]

    private static let unreachableHints = [
        "upstream_unreachable", "unable to connect", "is the computer able to access",
        "connection refused", "econnrefused", "enotfound", "eai_again", "fetch failed",
        "network", "socket hang up", "no route to host", "dns", "getaddrinfo", "tls", "proxy",
    ]
}

private extension Error {
    /// `localizedDescription` falls back to a locale-dependent template
    /// ("The operation couldn't be completed. (Domain error N.)") that says
    /// nothing beyond the domain and code, so treat that template as absent.
    /// Matching on the domain and code keeps this independent of the UI language.
    var presentableDescription: String? {
        let description = localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return nil }
        let error = self as NSError
        let isTemplate = description.hasPrefix("The operation couldn")
            || (!error.domain.isEmpty
                && error.code != 0
                && description.contains(error.domain)
                && description.contains("\(error.code)"))
        return isTemplate ? nil : description
    }
}

private extension String {
    /// Reverses the escaping that `String(describing:)` applies to a string.
    func unescapingStringDump() -> String {
        var result = ""
        var iterator = makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                result.append(character)
                break
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            default: result.append(escaped)
            }
        }
        return result
    }
}
