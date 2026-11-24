import Foundation
import Security
import Testing
@testable import Beeline

/// The Keychain helper on the simulator: what each status means, and moving items saved with
/// the default protection to after-first-unlock without losing them. A real locked phone (the
/// errSecInteractionNotAllowed path end to end) is device-only.
struct KeychainTests {
    @Test func statusMapping() {
        #expect(Keychain.mapped(errSecSuccess, Data("v".utf8)) == .value("v"))
        #expect(Keychain.mapped(errSecItemNotFound, nil) == .notFound)
        #expect(Keychain.mapped(errSecInteractionNotAllowed, nil) == .unreadable, "locked since the phone started")
        #expect(Keychain.mapped(errSecSuccess, nil) == .unreadable)
        #expect(Keychain.mapped(errSecAuthFailed, nil) == .unreadable)
    }

    @Test func readWriteNotFound() {
        let account = "test.\(UUID().uuidString)"
        #expect(Keychain.read(account) == .notFound)
        #expect(Keychain.set("hello", for: account))
        #expect(Keychain.read(account) == .value("hello"))
        #expect(Keychain.set("", for: account))
        #expect(Keychain.read(account) == .notFound)
    }

    @Test func migrationKeepsValuesAndChangesProtection() throws {
        let service = "beeline.tests.\(UUID().uuidString)"
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "old", kSecValueData as String: Data("kept".utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        let name = "KeychainTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        Keychain.migrateAccessibility(defaults: defaults, service: service)

        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "old", kSecReturnAttributes as String: true, kSecReturnData as String: true]
        var result: AnyObject?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let item = try #require(result as? [String: Any])
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect((item[kSecValueData as String] as? Data).map { String(decoding: $0, as: UTF8.self) } == "kept")
        #expect(defaults.bool(forKey: "keychain.afterFirstUnlock"), "done once")
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
