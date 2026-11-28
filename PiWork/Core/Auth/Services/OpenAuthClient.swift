import CryptoKit
import Foundation
import Security

struct OpenAuthConfiguration {
    static let issuerUserDefaultsKey = "auth.openauth.issuerURL"
    static let issuerEnvironmentKey = "PI_WORK_OPENAUTH_ISSUER_URL"
    private static let bundleIssuerKey = "OpenAuthIssuerURL"

    let issuerURL: URL
    let clientID: String
    let callbackScheme: String
    let callbackURL: URL

    static var current: OpenAuthConfiguration {
        let configuredIssuer = ProcessInfo.processInfo.environment[issuerEnvironmentKey]
            ?? UserDefaults.standard.string(forKey: issuerUserDefaultsKey)
            ?? Bundle.main.object(forInfoDictionaryKey: bundleIssuerKey) as? String
            ?? ""

        return OpenAuthConfiguration(
            issuerURL: URL(string: configuredIssuer.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "https://openauth.example.com")!,
            clientID: "pi-work-macos",
            callbackScheme: "pi-work",
            callbackURL: URL(string: "pi-work://auth/callback")!
        )
    }

    var isConfigured: Bool {
        guard let host = issuerURL.host else { return false }
        return host != "openauth.example.com"
    }
}

struct OpenAuthAuthorizationRequest {
    let url: URL
    let redirectURI: String
    let state: String
    let verifier: String
}

struct OpenAuthClient {
    /// The launch path refreshes expired tokens before the UI can be used, so
    /// a dead issuer must fail fast instead of holding the default 60s timeout.
    static let requestTimeout: TimeInterval = 10

    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private let configuration: OpenAuthConfiguration
    private let session: URLSession

    init(configuration: OpenAuthConfiguration = .current, session: URLSession = OpenAuthClient.defaultSession) {
        self.configuration = configuration
        self.session = session
    }

    func makeAuthorizationRequest(provider: String, redirectURI: String? = nil) throws -> OpenAuthAuthorizationRequest {
        guard configuration.isConfigured else {
            throw AuthError.missingOpenAuthIssuer
        }

        let redirectURI = redirectURI ?? defaultRedirectURI
        let pkce = try PKCEChallenge.make()
        let state = try PKCEChallenge.randomString(byteCount: 32)
        var components = URLComponents(url: configuration.issuerURL.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let url = components?.url else {
            throw AuthError.invalidAuthorizationURL
        }

        return OpenAuthAuthorizationRequest(
            url: url,
            redirectURI: redirectURI,
            state: state,
            verifier: pkce.verifier
        )
    }

    func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard isAcceptedCallbackURL(callbackURL) else {
            throw AuthError.invalidCallback
        }

        guard let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
            throw AuthError.invalidCallback
        }

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            throw AuthError.authorizationFailed(error)
        }

        guard queryItems.first(where: { $0.name == "state" })?.value == expectedState else {
            throw AuthError.invalidState
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }

        return code
    }

    func exchange(code: String, redirectURI: String, verifier: String) async throws -> AuthTokenSet {
        try await tokenRequest(parameters: [
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": verifier
        ])
    }

    func refresh(refreshToken: String) async throws -> AuthTokenSet {
        try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
    }

    func user(from accessToken: String) throws -> AuthUser {
        let payload = try decodeAccessToken(accessToken)
        return AuthUser(
            id: payload.properties.id,
            provider: payload.properties.provider,
            email: payload.properties.email,
            name: payload.properties.name,
            avatarURL: URL(string: payload.properties.avatarURL)
        )
    }

    func isAccessTokenValid(_ accessToken: String) -> Bool {
        guard let payload = try? decodeAccessToken(accessToken), let expiration = payload.exp else {
            return false
        }
        return Date(timeIntervalSince1970: TimeInterval(expiration)) > Date().addingTimeInterval(30)
    }

    private func tokenRequest(parameters: [String: String]) async throws -> AuthTokenSet {
        var request = URLRequest(url: configuration.issuerURL.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded(parameters).data(using: .utf8)

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidServerResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            // 5xx and 429 mean the issuer is down or throttling, not that the
            // refresh token is invalid. Report them as unreachable so callers
            // keep the stored credentials and retry instead of signing out.
            if httpResponse.statusCode >= 500 || httpResponse.statusCode == 429 {
                throw AuthError.networkUnavailable("HTTP \(httpResponse.statusCode)")
            }
            throw AuthError.tokenExchangeFailed(detail)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return AuthTokenSet(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresIn: TimeInterval(decoded.expiresIn),
            issuedAt: Date()
        )
    }

    /// Transport failures (offline, DNS, refused connection, timeout) are
    /// temporary by definition, so they surface as `networkUnavailable`
    /// instead of looking like a rejected credential.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw AuthError.networkUnavailable(error.localizedDescription)
        } catch {
            throw AuthError.networkUnavailable(error.localizedDescription)
        }
    }

    private func formURLEncoded(_ parameters: [String: String]) -> String {
        parameters
            .map { key, value in
                "\(key.urlFormEncoded)=\(value.urlFormEncoded)"
            }
            .joined(separator: "&")
    }

    private var defaultRedirectURI: String {
        configuration.callbackURL.absoluteString
    }

    private func isAcceptedCallbackURL(_ url: URL) -> Bool {
        if url.scheme == configuration.callbackScheme {
            return true
        }

        return url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")
    }

    private func decodeAccessToken(_ token: String) throws -> AccessTokenPayload {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            throw AuthError.invalidAccessToken
        }
        let payload = String(parts[1])
        guard let data = Data(base64URLEncoded: payload) else {
            throw AuthError.invalidAccessToken
        }
        return try JSONDecoder().decode(AccessTokenPayload.self, from: data)
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct AccessTokenPayload: Decodable {
    let exp: Int?
    let properties: AccessTokenProperties
}

private struct AccessTokenProperties: Decodable {
    let id: String
    let provider: String
    let email: String
    let name: String
    let avatarURL: String
}

private struct PKCEChallenge {
    let verifier: String
    let challenge: String

    static func make() throws -> PKCEChallenge {
        let verifier = try randomString(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return PKCEChallenge(verifier: verifier, challenge: challenge)
    }

    static func randomString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw AuthError.randomGenerationFailed(status)
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlFormAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlFormAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return allowed
    }()
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
