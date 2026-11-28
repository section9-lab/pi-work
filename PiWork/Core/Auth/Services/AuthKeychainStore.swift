import Foundation
import Security

/// Storage seam for the token set. `AuthSession` takes one so the launch and
/// retry paths can be tested without touching the real Keychain.
protocol AuthTokenStoring {
    func save(_ tokens: AuthTokenSet) throws
    func load() throws -> AuthTokenSet?
    func delete() throws
}

struct AuthKeychainStore {
    private let service = "com.section9lab.PiWork.auth"
    private let account = "openauth.tokens"

    func save(_ tokens: AuthTokenSet) throws {
        let data = try JSONEncoder().encode(tokens)
        try delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainFailure(status)
        }
    }

    func load() throws -> AuthTokenSet? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AuthError.keychainFailure(status)
        }
        return try JSONDecoder().decode(AuthTokenSet.self, from: data)
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychainFailure(status)
        }
    }
}

extension AuthKeychainStore: AuthTokenStoring {}
