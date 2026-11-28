import Foundation

public enum AuthError: Error {
    case missingOpenAuthIssuer
    case invalidAuthorizationURL
    case invalidCallback
    case invalidState
    case missingAuthorizationCode
    case authorizationFailed(String)
    case tokenExchangeFailed(String)
    case invalidServerResponse
    case invalidAccessToken
    case keychainFailure(OSStatus)
    case randomGenerationFailed(OSStatus)
    case webAuthenticationFailed(String)
    case invalidEmail
    case invalidEmailCode
    /// The issuer could not be reached, or answered with a temporary failure.
    /// This is the one failure that must not invalidate stored credentials:
    /// the app keeps working offline and retries in the background.
    case networkUnavailable(String)
}

extension AuthError {
    /// Whether this failure proves the stored refresh token is unusable.
    /// Only a rejection from the issuer (or an unreadable token) justifies
    /// deleting the keychain copy; a network outage must keep it.
    var discardsStoredCredentials: Bool {
        switch self {
        case .networkUnavailable:
            return false
        default:
            return true
        }
    }
}
