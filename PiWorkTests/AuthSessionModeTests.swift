import Foundation
import XCTest
@testable import PiWork

/// In-memory stand-in for the Keychain so tests never touch the real one.
final class InMemoryTokenStore: AuthTokenStoring {
    private let lock = NSLock()
    private var tokens: AuthTokenSet?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(tokens: AuthTokenSet? = nil) {
        self.tokens = tokens
    }

    var current: AuthTokenSet? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    func save(_ tokens: AuthTokenSet) throws {
        lock.lock()
        defer { lock.unlock() }
        self.tokens = tokens
        saveCount += 1
    }

    func load() throws -> AuthTokenSet? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        tokens = nil
        deleteCount += 1
    }
}

/// Stubs the issuer's `/token` endpoint so the launch path can be exercised
/// while offline, rejected, or healthy.
final class StubIssuerProtocol: URLProtocol {
    enum Response {
        case offline
        case status(Int, String)
        case tokens(accessToken: String, refreshToken: String)
    }

    private static let lock = NSLock()
    private static var queuedResponses: [Response] = []
    private static var issuedRequests = 0

    static func reset(_ responses: [Response]) {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses = responses
        issuedRequests = 0
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return issuedRequests
    }

    private static func next() -> Response {
        lock.lock()
        defer { lock.unlock() }
        issuedRequests += 1
        if queuedResponses.isEmpty { return .status(500, "") }
        return queuedResponses.removeFirst()
    }

    // URLProtocol subclasses must override these class methods, so `static`
    // is not an option here.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.next() {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .status(let code, let body):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://issuer.test/token")!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .tokens(let accessToken, let refreshToken):
            let body = """
            {"access_token":"\(accessToken)","refresh_token":"\(refreshToken)","expires_in":3600}
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://issuer.test/token")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class AuthSessionModeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var issuerConfiguration: OpenAuthConfiguration!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        suiteName = "AuthSessionModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)

        issuerConfiguration = OpenAuthConfiguration(
            issuerURL: URL(string: "https://issuer.test")!,
            clientID: "pi-work-macos",
            callbackScheme: "pi-work",
            callbackURL: URL(string: "pi-work://auth/callback")!
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubIssuerProtocol.self]
        session = URLSession(configuration: configuration)
        StubIssuerProtocol.reset([])
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        issuerConfiguration = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAccessToken(expiresIn: TimeInterval, email: String = "local@example.com") throws -> String {
        let payload: [String: Any] = [
            "exp": Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970),
            "properties": [
                "id": "user-1",
                "provider": "google",
                "email": email,
                "name": "Test User",
                "avatarURL": ""
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    private func makeSession(store: InMemoryTokenStore, factoryCalls: @escaping () -> Void = {}) -> AuthSession {
        let client = OpenAuthClient(configuration: issuerConfiguration, session: session)
        let session = AuthSession(
            defaults: defaults,
            keychainStore: store,
            makeClient: {
                factoryCalls()
                return client
            }
        )
        session.offlineRetryDelays = []
        return session
    }

    // MARK: - Local mode

    func testLocalModeUnlocksTheAppWithoutAnAccount() throws {
        let store = InMemoryTokenStore()
        let session = makeSession(store: store)

        session.enterLocalMode()

        XCTAssertTrue(session.canUseApp)
        XCTAssertFalse(session.isSignedIn)
        XCTAssertTrue(session.isLocalMode)
        XCTAssertNil(session.user)
        XCTAssertEqual(defaults.string(forKey: AuthAccessModeStore.accessModeKey), "local")
    }

    func testLocalModeKeepsStoredCredentialsAndSurvivesRelaunch() throws {
        let tokens = AuthTokenSet(
            accessToken: try makeAccessToken(expiresIn: 3600),
            refreshToken: "refresh",
            expiresIn: 3600,
            issuedAt: Date()
        )
        let store = InMemoryTokenStore(tokens: tokens)
        let first = makeSession(store: store)

        first.enterLocalMode()

        XCTAssertNotNil(store.current)
        XCTAssertEqual(store.deleteCount, 0)

        let relaunched = makeSession(store: store)

        XCTAssertTrue(relaunched.isLocalMode)
        XCTAssertTrue(relaunched.canUseApp)
        XCTAssertEqual(StubIssuerProtocol.requestCount, 0, "Local mode must not call the auth service")
    }

    func testLocalModeLaunchSkipsRestoreEntirely() async throws {
        defaults.set(AuthAccessMode.local.rawValue, forKey: AuthAccessModeStore.accessModeKey)
        var factoryCalls = 0
        let session = makeSession(store: InMemoryTokenStore(), factoryCalls: { factoryCalls += 1 })

        await session.restoreSessionOnLaunch()

        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(StubIssuerProtocol.requestCount, 0)
        XCTAssertTrue(session.canUseApp)
    }

    func testRequestingSignInFromLocalModeReturnsToOnboarding() {
        let session = makeSession(store: InMemoryTokenStore())

        session.enterLocalMode()
        session.requestSignIn()

        XCTAssertFalse(session.canUseApp)
        XCTAssertFalse(session.isLocalMode)
    }

    func testSignOutLeavesNoSessionBehind() async throws {
        let tokens = AuthTokenSet(
            accessToken: try makeAccessToken(expiresIn: 3600),
            refreshToken: "refresh",
            expiresIn: 3600,
            issuedAt: Date()
        )
        let store = InMemoryTokenStore(tokens: tokens)
        let session = makeSession(store: store)
        StubIssuerProtocol.reset([.offline])

        await session.restoreSessionOnLaunch()
        session.signOut()

        XCTAssertNil(store.current)
        XCTAssertEqual(session.accessMode, .signedOut)
        XCTAssertFalse(session.canUseApp)
        XCTAssertFalse(session.isOffline)
    }

    // MARK: - Launch restore

    func testValidTokenUsesNoNetworkRequest() async throws {
        let tokens = AuthTokenSet(
            accessToken: try makeAccessToken(expiresIn: 3600),
            refreshToken: "refresh",
            expiresIn: 3600,
            issuedAt: Date()
        )
        defaults.set(AuthAccessMode.signedIn.rawValue, forKey: AuthAccessModeStore.accessModeKey)
        let session = makeSession(store: InMemoryTokenStore(tokens: tokens))

        await session.restoreSessionOnLaunch()

        XCTAssertEqual(session.accessMode, .signedIn)
        XCTAssertEqual(session.user?.email, "local@example.com")
        XCTAssertFalse(session.isOffline)
        XCTAssertEqual(StubIssuerProtocol.requestCount, 0)
    }

    func testUnreachableIssuerKeepsCredentialsAndTheLocalAppUsable() async throws {
        let tokens = AuthTokenSet(
            accessToken: try makeAccessToken(expiresIn: -600),
            refreshToken: "refresh",
            expiresIn: 3600,
            issuedAt: Date()
        )
        let store = InMemoryTokenStore(tokens: tokens)
        defaults.set(AuthAccessMode.signedIn.rawValue, forKey: AuthAccessModeStore.accessModeKey)
        let session = makeSession(store: store)
        StubIssuerProtocol.reset([.offline])

        await session.restoreSessionOnLaunch()

        XCTAssertEqual(session.accessMode, .signedIn, "A network outage must not sign the user out")
        XCTAssertTrue(session.canUseApp)
        XCTAssertTrue(session.isOffline)
        XCTAssertNotNil(store.current, "Tokens must survive a transient failure")
        XCTAssertEqual(store.deleteCount, 0)
        XCTAssertEqual(session.user?.email, "local@example.com")
        XCTAssertNil(session.lastErrorMessage)
    }

    func testTemporaryServerFailureAlsoKeepsTheSession() async throws {
        let tokens = AuthTokenSet(
            accessToken: try makeAccessToken(expiresIn: -600),
            refreshToken: "refresh",
            expiresIn: 3600,
            issuedAt: Date()
        )
        let store = InMemoryTokenStore(tokens: tokens)
        defaults.set(AuthAccessMode.signedIn.rawValue, forKey: AuthAccessModeStore.accessModeKey)
        let session = makeSession(store: store)
        StubIssuerProtocol.reset([.status(503, "upstream unavailable")])

        await session.restoreSessionOnLaunch()

        XCTAssertEqual(session.accessMode, .signedIn)
        XCTAssertTrue(session.isOffline)
        XCTAssertNotNil(store.current)
    }

    func testRejectedRefreshClearsCredentialsAndReturnsToOnboarding() async throws {
        let tokens = AuthTokenSet(
            accessToken: try makeAccessToken(expiresIn: -600),
            refreshToken: "refresh",
            expiresIn: 3600,
            issuedAt: Date()
        )
        let store = InMemoryTokenStore(tokens: tokens)
        defaults.set(AuthAccessMode.signedIn.rawValue, forKey: AuthAccessModeStore.accessModeKey)
        let session = makeSession(store: store)
        StubIssuerProtocol.reset([.status(401, #"{"error":"invalid_grant"}"#)])

        await session.restoreSessionOnLaunch()

        XCTAssertEqual(session.accessMode, .signedOut)
        XCTAssertFalse(session.canUseApp)
        XCTAssertNil(store.current)
        XCTAssertEqual(store.deleteCount, 1)
        XCTAssertNotNil(session.lastErrorMessage)
        XCTAssertFalse(session.isOffline)
    }

    func testMissingCredentialsFallBackToOnboarding() async throws {
        defaults.set(AuthAccessMode.signedIn.rawValue, forKey: AuthAccessModeStore.accessModeKey)
        let session = makeSession(store: InMemoryTokenStore())

        await session.restoreSessionOnLaunch()

        XCTAssertEqual(session.accessMode, .signedOut)
        XCTAssertEqual(StubIssuerProtocol.requestCount, 0)
    }

    func testBackgroundRetryRecoversAnOfflineSession() async throws {
        let tokens = AuthTokenSet(
            accessToken: try makeAccessToken(expiresIn: -600),
            refreshToken: "refresh",
            expiresIn: 3600,
            issuedAt: Date()
        )
        let store = InMemoryTokenStore(tokens: tokens)
        let fresh = try makeAccessToken(expiresIn: 3600)
        defaults.set(AuthAccessMode.signedIn.rawValue, forKey: AuthAccessModeStore.accessModeKey)
        let session = makeSession(store: store)
        session.offlineRetryDelays = [.milliseconds(10), .milliseconds(10)]
        StubIssuerProtocol.reset([.offline, .tokens(accessToken: fresh, refreshToken: "refresh-2")])

        await session.restoreSessionOnLaunch()
        XCTAssertTrue(session.isOffline)

        let deadline = Date().addingTimeInterval(5)
        while session.isOffline && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(session.isOffline, "The retry loop should recover once the issuer answers")
        XCTAssertEqual(session.accessMode, .signedIn)
        XCTAssertEqual(store.current?.refreshToken, "refresh-2")
        XCTAssertEqual(StubIssuerProtocol.requestCount, 2)
    }
}
