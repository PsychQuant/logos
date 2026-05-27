import Foundation
import Security

/// E.2: Reads/writes the SYSTEM Claude Code-credentials Keychain entry
/// (the one claude CLI itself uses at runtime). This is the swap target
/// for multi-account: we swap this single entry's value between accounts.
///
/// Distinct from `AccountCredentialStore` (E.1) which holds Logos's own
/// per-account backups at service "app.getlogos.logos.credentials".
///
/// Schema discovered 2026-05-27:
///   service: "Claude Code-credentials"
///   account: $USER (e.g. "che")
///   value:   JSON blob with keys claudeAiOauth + mcpOAuth
@MainActor
public protocol SystemKeychainBridge {
    /// Read the system Claude credentials entry. Returns nil if not set
    /// (e.g. user never ran `claude login`).
    func read() throws -> Data?

    /// Write the system Claude credentials entry. Overwrites any existing value.
    func write(_ data: Data) throws

    /// Delete the system Claude credentials entry (forces claude to re-login).
    func delete() throws

    /// Whether the entry currently exists.
    func exists() -> Bool
}

/// Production implementation backed by real macOS Keychain.
@MainActor
public final class RealSystemKeychainBridge: SystemKeychainBridge {

    private let service: String
    private let account: String

    public init(
        service: String = "Claude Code-credentials",
        account: String = NSUserName()
    ) {
        self.service = service
        self.account = account
    }

    public func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AccountCredentialStoreError.keychainError(status)
        }
        return result as? Data
    }

    public func write(_ data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Try update first; if not exists, add.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            updateAttrs as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addAttrs = baseQuery
            addAttrs[kSecValueData as String] = data
            addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AccountCredentialStoreError.keychainError(addStatus)
            }
            return
        }
        throw AccountCredentialStoreError.keychainError(updateStatus)
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw AccountCredentialStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw AccountCredentialStoreError.keychainError(status)
        }
    }

    public func exists() -> Bool {
        (try? read()) != nil
    }
}

/// In-memory implementation for tests. Mimics single-entry semantics.
@MainActor
public final class InMemorySystemKeychainBridge: SystemKeychainBridge {

    private var stored: Data?

    public init(initial: Data? = nil) {
        self.stored = initial
    }

    public func read() throws -> Data? { stored }
    public func write(_ data: Data) throws { stored = data }
    public func delete() throws {
        if stored == nil { throw AccountCredentialStoreError.notFound }
        stored = nil
    }
    public func exists() -> Bool { stored != nil }
}
