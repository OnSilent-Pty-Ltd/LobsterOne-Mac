import Foundation
import Security

/// Where pasted access keys live. A protocol so the credential provider can be
/// tested without touching the real Keychain.
nonisolated protocol AWSSecretStoring: Sendable {
    func readAccessKeys() -> (id: String, secret: String)?
    func saveAccessKeys(id: String, secret: String) throws
    func deleteAccessKeys() throws
}

nonisolated enum AWSKeychainError: Error, Equatable {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
}

/// Generic-password items in the login Keychain, next to the app's other
/// secrets (same service as KeychainService, separate accounts).
nonisolated struct AWSKeychainSecrets: AWSSecretStoring {
    static let idAccount = "aws-access-key-id"
    static let secretAccount = "aws-secret-access-key"

    let service: String

    init(service: String = "com.lobsterone.mac") {
        self.service = service
    }

    func readAccessKeys() -> (id: String, secret: String)? {
        guard let id = read(Self.idAccount), !id.isEmpty,
              let secret = read(Self.secretAccount), !secret.isEmpty else { return nil }
        return (id, secret)
    }

    /// Saves both or neither: a half-written pair would look connected and then fail.
    func saveAccessKeys(id: String, secret: String) throws {
        do {
            try save(Self.idAccount, id)
            try save(Self.secretAccount, secret)
        } catch {
            try? deleteAccessKeys()
            throw error
        }
    }

    func deleteAccessKeys() throws {
        try delete(Self.idAccount)
        try delete(Self.secretAccount)
    }

    private func save(_ account: String, _ value: String) throws {
        try? delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AWSKeychainError.saveFailed(status) }
    }

    private func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AWSKeychainError.deleteFailed(status)
        }
    }
}
