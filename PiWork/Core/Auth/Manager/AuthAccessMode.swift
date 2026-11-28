import Foundation

/// What the app is allowed to do after launch.
///
/// `local` is a first-class choice, not a fake sign-in: no account, no cloud
/// request, and every feature that only needs the local runtime keeps working.
enum AuthAccessMode: String, CaseIterable {
    /// A stored token set was validated (or is still usable offline).
    case signedIn
    /// The user chose to use PiWork without an account.
    case local
    /// Nothing chosen yet: onboarding is on screen.
    case signedOut

    /// Single gate for the root view and for starting the agent runtime.
    var canUseApp: Bool { self != .signedOut }
}

/// Persists the access mode and migrates the boolean flag written by builds
/// that only had a signed-in / signed-out gate.
struct AuthAccessModeStore {
    static let accessModeKey = "auth.accessMode"

    /// Legacy key: `true` meant "was signed in". Still written so a downgrade
    /// keeps reading something truthful.
    static let legacyIsSignedInKey = "auth.isSignedIn"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AuthAccessMode {
        if let raw = defaults.string(forKey: Self.accessModeKey),
           let stored = AuthAccessMode(rawValue: raw) {
            return stored
        }

        // Migration from the boolean gate. Keep the optimistic entry so the
        // app does not flash onboarding for an existing user; the launch
        // restore validates the credentials and falls back when they are gone.
        if defaults.bool(forKey: Self.legacyIsSignedInKey) {
            return .signedIn
        }

        return .signedOut
    }

    func save(_ mode: AuthAccessMode) {
        defaults.set(mode.rawValue, forKey: Self.accessModeKey)
        defaults.set(mode == .signedIn, forKey: Self.legacyIsSignedInKey)
    }
}
