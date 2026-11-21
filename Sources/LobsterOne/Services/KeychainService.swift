import Combine
import Foundation
import Security

struct CognitoTokens: Equatable {
    let idToken: String
    let refreshToken: String
}

final class KeychainService {
    private let serviceName: String

    private enum Account: String {
        case apiKey = "api-key"
        case apiKeyId = "api-key-id"
        case idToken = "id-token"
        case refreshToken = "refresh-token"
    }

    init(serviceName: String = "com.lobsterone.mac") {
        self.serviceName = serviceName
    }

    func saveAPIKey(_ key: String) throws {
        try save(account: .apiKey, data: key)
    }

    func getAPIKey() throws -> String? {
        try get(account: .apiKey)
    }

    func saveAPIKeyId(_ id: String) throws {
        try save(account: .apiKeyId, data: id)
    }

    func getAPIKeyId() throws -> String? {
        try get(account: .apiKeyId)
    }

    func saveTokens(idToken: String, refreshToken: String) throws {
        try save(account: .idToken, data: idToken)
        try save(account: .refreshToken, data: refreshToken)
    }

    func getTokens() throws -> CognitoTokens? {
        guard let idToken = try get(account: .idToken),
              let refreshToken = try get(account: .refreshToken) else {
            return nil
        }
        return CognitoTokens(idToken: idToken, refreshToken: refreshToken)
    }

    func deleteAll() throws {
        for account in [Account.apiKey, .apiKeyId, .idToken, .refreshToken] {
            try delete(account: account)
        }
    }

    private func save(account: Account, data: String) throws {
        let dataBytes = Data(data.utf8)
        try? delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account.rawValue,
            kSecValueData as String: dataBytes,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func get(account: Account) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.readFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    private func delete(account: Account) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
}
