import Foundation
import Security

/// READ-ONLY view of the shared SYSTEM `Claude Code-credentials` Keychain entry
/// (the bare entry a plain-terminal `claude login` writes).
///
/// Per PsychQuant/logos#12 the write/delete path was removed: Logos no longer
/// swaps this shared entry between accounts (that cross-identity `SecItem` write
/// could trigger the macOS "找不到鑰匙圈" reset dialog). Each account now reads its
/// own per-`CLAUDE_CONFIG_DIR` Keychain item, set at spawn time by
/// `ClaudeProcessConfig`. This bridge is retained read-only so the capture/import
/// flow (`addByCapturingCurrent`) and migration can INSPECT the bare entry; it is
/// never mutated.
///
/// Distinct from `AccountCredentialStore` which holds Logos's own per-account
/// backups at service "app.getlogos.logos.credentials".
///
/// Schema (service: "Claude Code-credentials", account: $USER, value: JSON blob
/// with keys claudeAiOauth + mcpOAuth).
@MainActor
public protocol SystemKeychainBridge {
    /// Read the system Claude credentials entry. Returns nil if not set
    /// (e.g. user never ran `claude login`).
    func read() throws -> Data?

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
    public func exists() -> Bool { stored != nil }
}
