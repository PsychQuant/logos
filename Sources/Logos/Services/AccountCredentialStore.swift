import Foundation
import Security

public enum AccountCredentialStoreError: Error, Equatable {
    case notFound
    case keychainError(OSStatus)
    case invalidData
}

@MainActor
public protocol AccountCredentialStore {
    func save(accountId: String, credentials: Data) throws
    func load(accountId: String) throws -> Data
    func delete(accountId: String) throws
    func listAccountIds() throws -> [String]
}

/// Production implementation backed by macOS Keychain.
@MainActor
public final class KeychainCredentialStore: AccountCredentialStore {

    private let service = "app.getlogos.logos.credentials"

    public init() {}

    public func save(accountId: String, credentials: Data) throws {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecValueData as String: credentials,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(attrs as CFDictionary)  // overwrite semantics
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AccountCredentialStoreError.keychainError(status)
        }
    }

    public func load(accountId: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw AccountCredentialStoreError.notFound
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AccountCredentialStoreError.keychainError(status)
        }
        return data
    }

    public func delete(accountId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw AccountCredentialStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw AccountCredentialStoreError.keychainError(status)
        }
    }

    public func listAccountIds() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw AccountCredentialStoreError.keychainError(status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// In-memory implementation for tests.
@MainActor
public final class InMemoryCredentialStore: AccountCredentialStore {

    private var storage: [String: Data] = [:]
    public init() {}

    public func save(accountId: String, credentials: Data) throws {
        storage[accountId] = credentials
    }

    public func load(accountId: String) throws -> Data {
        guard let data = storage[accountId] else {
            throw AccountCredentialStoreError.notFound
        }
        return data
    }

    public func delete(accountId: String) throws {
        guard storage.removeValue(forKey: accountId) != nil else {
            throw AccountCredentialStoreError.notFound
        }
    }

    public func listAccountIds() throws -> [String] {
        Array(storage.keys)
    }
}
