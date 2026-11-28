import Foundation
import SwiftUI

extension AuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingOpenAuthIssuer:
            return L10n.string("auth.error.missing_issuer")
        case .invalidAuthorizationURL:
            return L10n.string("auth.error.invalid_url")
        case .invalidCallback, .missingAuthorizationCode:
            return L10n.string("auth.error.invalid_callback")
        case .invalidState:
            return L10n.string("auth.error.state_mismatch")
        case .authorizationFailed(let message):
            return L10n.format("auth.error.authorization_failed", message)
        case .tokenExchangeFailed(let message):
            return L10n.format("auth.error.token_exchange_failed", message)
        case .invalidServerResponse:
            return L10n.string("auth.error.invalid_response")
        case .invalidAccessToken:
            return L10n.string("auth.error.invalid_credentials")
        case .keychainFailure(let status):
            return L10n.format("auth.error.keychain", Int(status))
        case .randomGenerationFailed(let status):
            return L10n.format("auth.error.random", Int(status))
        case .webAuthenticationFailed(let message):
            return L10n.format("auth.error.browser", message)
        case .invalidEmail:
            return L10n.string("auth.error.invalid_email")
        case .invalidEmailCode:
            return L10n.string("auth.error.invalid_code")
        case .networkUnavailable:
            return L10n.string("auth.error.network_unavailable")
        }
    }
}

private struct OpenAuthSessionAuthorization {
    let callbackURL: URL
    let redirectURI: String
    let request: OpenAuthAuthorizationRequest
}

@MainActor
final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    private static let providerKey = "auth.provider"
    private static let userKey = "auth.user"

    enum Provider: String, Codable {
        case google
        case email

        /// The `provider` query parameter the openauth issuer dispatches on.
        /// We keep `Provider` Swift-side names readable while preserving the
        /// exact string the issuer expects (the issuer registered the
        /// CodeProvider under the key "code").
        var issuerKey: String {
            switch self {
            case .google: return "google"
            case .email: return "code"
            }
        }

        /// Shown under the account name in the sidebar footer popover.
        var accountSubtitle: String {
            switch self {
            case .google:
                return L10n.string("account.google")
            case .email:
                return L10n.string("account.email")
            }
        }
    }

    @Published private(set) var accessMode: AuthAccessMode {
        didSet {
            modeStore.save(accessMode)
        }
    }
    @Published private(set) var provider: Provider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
        }
    }
    @Published private(set) var user: AuthUser? {
        didSet {
            persistUser(user)
        }
    }
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastErrorMessage: String?

    /// True when the launch refresh failed for a transport reason. The session
    /// stays signed in and the local runtime keeps working; a background task
    /// retries until the issuer answers or the retry schedule runs out.
    @Published private(set) var isOffline = false

    /// Email of the address we just sent a code to. Drives the "code sent
    /// to <email>" hint in the verify step and is the source of truth for
    /// resends so the user can't change it mid-flow.
    @Published private(set) var pendingEmail: String?

    private let defaults: UserDefaults
    private let keychainStore: AuthTokenStoring
    private let modeStore: AuthAccessModeStore
    private let webAuthenticator = OAuthWebAuthenticator()
    private let makeClient: () -> OpenAuthClient

    /// Backoff between background refresh attempts while the issuer is
    /// unreachable. Empty disables the retry loop (tests use that).
    var offlineRetryDelays: [Duration] = [
        .seconds(20), .seconds(45), .seconds(90), .seconds(180), .seconds(300)
    ]

    private var offlineRetryTask: Task<Void, Never>?

    /// Owns the PKCE state for one email-OTP attempt. Recreated on cancel
    /// or when a fresh request comes in. Nil whenever the user isn't mid-
    /// flow.
    private var pendingEmailClient: EmailOTPClient?

    init(
        defaults: UserDefaults = .standard,
        keychainStore: AuthTokenStoring = AuthKeychainStore(),
        makeClient: @escaping () -> OpenAuthClient = { OpenAuthClient() }
    ) {
        self.defaults = defaults
        self.modeStore = AuthAccessModeStore(defaults: defaults)
        self.keychainStore = keychainStore
        self.makeClient = makeClient
        self.user = Self.loadPersistedUser(defaults: defaults)
        self.accessMode = modeStore.load()
        let storedProvider = defaults.string(forKey: Self.providerKey)
        self.provider = storedProvider.flatMap(Provider.init(rawValue:)) ?? .google
    }

    var isSignedIn: Bool { accessMode == .signedIn }
    var canUseApp: Bool { accessMode.canUseApp }
    var isLocalMode: Bool { accessMode == .local }

    /// Validates the stored credentials once per cold start.
    ///
    /// Only a rejection from the issuer clears the Keychain copy. A transport
    /// failure keeps the credentials, keeps the app usable and retries in the
    /// background, because a dead auth service must not lock the user out of
    /// their local sessions.
    func restoreSessionOnLaunch() async {
        guard accessMode == .signedIn else { return }

        guard let tokens = try? keychainStore.load() else {
            accessMode = .signedOut
            user = nil
            return
        }

        let client = makeClient()
        if client.isAccessTokenValid(tokens.accessToken) {
            do {
                applyAuthenticatedUser(try client.user(from: tokens.accessToken))
            } catch {
                // The claims are unreadable, but the token is still valid, so
                // keep the persisted profile instead of signing out.
                if user == nil {
                    user = Self.loadPersistedUser(defaults: defaults)
                }
            }
            return
        }

        do {
            let refreshed = try await client.refresh(refreshToken: tokens.refreshToken)
            try keychainStore.save(refreshed)
            applyAuthenticatedUser(try client.user(from: refreshed.accessToken))
        } catch let error as AuthError where error.discardsStoredCredentials {
            try? keychainStore.delete()
            isOffline = false
            accessMode = .signedOut
            user = nil
            lastErrorMessage = error.localizedDescription
        } catch {
            applyOfflineSession(tokens: tokens)
        }
    }

    func signInWithGoogle() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        lastErrorMessage = nil

        let client = makeClient()
        do {
            let authorization = try await authorizeWithGoogle(client: client)
            let code = try client.authorizationCode(
                from: authorization.callbackURL,
                expectedState: authorization.request.state
            )
            let tokens = try await client.exchange(
                code: code,
                redirectURI: authorization.redirectURI,
                verifier: authorization.request.verifier
            )

            try keychainStore.save(tokens)
            applyAuthenticatedUser(try client.user(from: tokens.accessToken))
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Email OTP login is split into two steps so the UI can show progress
    /// between "send code" and "verify code" and so we don't drag a long-
    /// lived task through both. Each call recreates the underlying client.
    func requestEmailCode(_ email: String) async throws {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        lastErrorMessage = nil

        let client = EmailOTPClient()
        do {
            try await client.requestCode(email: email)
            pendingEmailClient = client
            pendingEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func resendEmailCode() async throws {
        guard let client = pendingEmailClient, let email = pendingEmail else {
            throw AuthError.invalidCallback
        }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        lastErrorMessage = nil
        do {
            try await client.resendCode(email: email)
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func verifyEmailCode(_ code: String) async throws {
        guard let client = pendingEmailClient else {
            throw AuthError.invalidCallback
        }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        lastErrorMessage = nil
        do {
            let tokens = try await client.verifyCode(code)
            let openauth = makeClient()
            try keychainStore.save(tokens)
            applyAuthenticatedUser(try openauth.user(from: tokens.accessToken))
            cancelEmailLogin()
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func cancelEmailLogin() {
        pendingEmailClient = nil
        pendingEmail = nil
    }

    /// Clear the surface-area error so a fresh step starts with a clean
    /// slate (e.g. switching from picker → email input shouldn't carry over
    /// a previous Google failure message).
    func clearLastError() {
        lastErrorMessage = nil
    }

    /// Leaves the account surface for a strictly local session. The Keychain
    /// copy is kept: the user may come back, and nothing about local mode
    /// should invalidate a valid credential.
    func enterLocalMode() {
        offlineRetryTask?.cancel()
        cancelEmailLogin()
        clearLastError()
        isOffline = false
        user = nil
        accessMode = .local
    }

    /// Drops back to onboarding from local mode so the user can sign in again.
    func requestSignIn() {
        guard accessMode == .local else { return }
        clearLastError()
        accessMode = .signedOut
    }

    func signOut() {
        offlineRetryTask?.cancel()
        try? keychainStore.delete()
        cancelEmailLogin()
        user = nil
        isOffline = false
        lastErrorMessage = nil
        accessMode = .signedOut
    }

    private func applyAuthenticatedUser(_ user: AuthUser) {
        self.user = user
        provider = Provider(rawValue: user.provider) ?? .google
        isOffline = false
        accessMode = .signedIn
        lastErrorMessage = nil
        offlineRetryTask?.cancel()
        offlineRetryTask = nil
    }

    /// Keeps the session signed in while the issuer is unreachable.
    private func applyOfflineSession(tokens: AuthTokenSet) {
        isOffline = true
        lastErrorMessage = nil
        if let decoded = try? makeClient().user(from: tokens.accessToken) {
            user = decoded
            provider = Provider(rawValue: decoded.provider) ?? .google
        } else if user == nil {
            user = Self.loadPersistedUser(defaults: defaults)
        }
        accessMode = .signedIn
        startOfflineRetry()
    }

    private func startOfflineRetry() {
        offlineRetryTask?.cancel()
        guard !offlineRetryDelays.isEmpty else { return }

        offlineRetryTask = Task { [weak self] in
            guard let delays = self?.offlineRetryDelays else { return }
            for delay in delays {
                if Task.isCancelled { return }
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                guard let self else { return }
                if await self.refreshWhileOffline() { return }
            }
        }
    }

    /// Returns true when retrying should stop: either the session recovered or
    /// the issuer proved the refresh token unusable.
    private func refreshWhileOffline() async -> Bool {
        guard accessMode == .signedIn, isOffline, let tokens = try? keychainStore.load() else {
            return true
        }

        let client = makeClient()
        do {
            let refreshed = try await client.refresh(refreshToken: tokens.refreshToken)
            try keychainStore.save(refreshed)
            applyAuthenticatedUser(try client.user(from: refreshed.accessToken))
            return true
        } catch let error as AuthError where error.discardsStoredCredentials {
            try? keychainStore.delete()
            isOffline = false
            accessMode = .signedOut
            user = nil
            lastErrorMessage = error.localizedDescription
            return true
        } catch {
            return false
        }
    }

    private func authorizeWithGoogle(client: OpenAuthClient) async throws -> OpenAuthSessionAuthorization {
        let authentication = try await webAuthenticator.authenticate { redirectURI in
            let request = try client.makeAuthorizationRequest(provider: "google", redirectURI: redirectURI)
            return OAuthWebAuthenticationRequest(
                authorizationURL: request.url,
                redirectURI: request.redirectURI,
                context: request
            )
        }

        return OpenAuthSessionAuthorization(
            callbackURL: authentication.callbackURL,
            redirectURI: authentication.redirectURI,
            request: authentication.context
        )
    }

    private static func loadPersistedUser(defaults: UserDefaults = .standard) -> AuthUser? {
        guard let data = defaults.data(forKey: userKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthUser.self, from: data)
    }

    private func persistUser(_ user: AuthUser?) {
        if let user, let data = try? JSONEncoder().encode(user) {
            defaults.set(data, forKey: Self.userKey)
        } else {
            defaults.removeObject(forKey: Self.userKey)
        }
    }
}
