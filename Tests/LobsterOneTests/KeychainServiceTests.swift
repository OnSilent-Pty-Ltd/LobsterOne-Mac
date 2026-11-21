import Testing
import Foundation
@testable import LobsterOne

@Test func saveAndRetrieveAPIKey() throws {
    let keychain = KeychainService(serviceName: "com.lobsterone.mac.test.\(UUID().uuidString)")
    defer { try? keychain.deleteAll() }

    try keychain.saveAPIKey("rc_test123")
    #expect(try keychain.getAPIKey() == "rc_test123")
}

@Test func saveAndRetrieveAPIKeyId() throws {
    let keychain = KeychainService(serviceName: "com.lobsterone.mac.test.\(UUID().uuidString)")
    defer { try? keychain.deleteAll() }

    try keychain.saveAPIKeyId("uuid-123")
    #expect(try keychain.getAPIKeyId() == "uuid-123")
}

@Test func saveAndRetrieveTokens() throws {
    let keychain = KeychainService(serviceName: "com.lobsterone.mac.test.\(UUID().uuidString)")
    defer { try? keychain.deleteAll() }

    try keychain.saveTokens(idToken: "id_tok", refreshToken: "ref_tok")
    let tokens = try keychain.getTokens()
    #expect(tokens?.idToken == "id_tok")
    #expect(tokens?.refreshToken == "ref_tok")
}

@Test func getAPIKeyReturnsNilWhenEmpty() throws {
    let keychain = KeychainService(serviceName: "com.lobsterone.mac.test.\(UUID().uuidString)")
    #expect(try keychain.getAPIKey() == nil)
}

@Test func deleteAllRemovesEverything() throws {
    let keychain = KeychainService(serviceName: "com.lobsterone.mac.test.\(UUID().uuidString)")
    try keychain.saveAPIKey("rc_test")
    try keychain.saveTokens(idToken: "id", refreshToken: "ref")
    try keychain.deleteAll()
    #expect(try keychain.getAPIKey() == nil)
    #expect(try keychain.getTokens() == nil)
}
