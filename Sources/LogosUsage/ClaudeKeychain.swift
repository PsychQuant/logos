import Foundation
import CryptoKit

/// OAuth credentials Claude Code stores in the login Keychain.
///
/// READ-ONLY by design: MultiStats reads a token to make a single in-memory
/// usage request and nothing more. It never writes, refreshes, or persists a
/// token, and never logs one. An expired token surfaces as a display state,
/// not an automatic refresh.
public struct StoredCredentials: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        subscriptionType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    /// Whether the access token is past its expiry as of `now`. Unknown expiry
    /// is treated as not-expired — let the API return 401 rather than
    /// pre-emptively hiding an account.
    public func isExpired(asOf now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }
}

/// Computes Keychain service names and parses stored credentials. Pure logic —
/// no Keychain or network access — so it is fully unit-testable.
public enum ClaudeKeychain {
    static let baseService = "Claude Code-credentials"

    /// The generic-password service name Claude Code stores credentials under.
    ///
    /// - default account (`~/.claude`, no `CLAUDE_CONFIG_DIR`): the bare
    ///   `"Claude Code-credentials"`.
    /// - `CLAUDE_CONFIG_DIR` account (Logos): suffixed with the first 8 hex
    ///   chars of the SHA-256 of the config dir's absolute path (confirmed by
    ///   matching live Keychain items).
    public static func serviceName(forConfigDir configDir: URL, isDefault: Bool) -> String {
        guard !isDefault else { return baseService }
        let path = configDir.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(baseService)-\(hex.prefix(8))"
    }

    /// Parses the `claudeAiOauth` object out of raw credentials JSON. Returns
    /// nil for malformed data or a missing/empty access token. `expiresAt` in
    /// the stored JSON is Unix epoch **milliseconds**.
    public static func parseCredentials(fromData data: Data) -> StoredCredentials? {
        struct Envelope: Decodable {
            struct OAuth: Decodable {
                let accessToken: String?
                let refreshToken: String?
                let expiresAt: Double?
                let subscriptionType: String?
            }
            let claudeAiOauth: OAuth?
        }
        guard let oauth = (try? JSONDecoder().decode(Envelope.self, from: data))?.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty else { return nil }
        return StoredCredentials(
            accessToken: token,
            refreshToken: oauth.refreshToken,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth.subscriptionType)
    }
}

/// Abstracts the actual Keychain lookup so callers can inject a fake in tests.
public protocol KeychainReading: Sendable {
    /// Raw generic-password data for `service`, or nil if absent / denied.
    func readGenericPassword(service: String) -> Data?
}

/// Live `KeychainReading` backed by the Security framework. Read-only:
/// only ever issues `SecItemCopyMatching`, never `SecItemAdd`/`Update`/`Delete`.
public struct SystemKeychainReader: KeychainReading {
    public init() {}

    public func readGenericPassword(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }
}

/// Reads and parses an account's stored credentials, wiring the service-name
/// computation to the injected Keychain backend.
public struct KeychainCredentialsReader: Sendable {
    private let keychain: KeychainReading

    public init(keychain: KeychainReading = SystemKeychainReader()) {
        self.keychain = keychain
    }

    public func credentials(for account: Account) -> StoredCredentials? {
        let service = ClaudeKeychain.serviceName(
            forConfigDir: account.configDir, isDefault: account.isDefault)
        guard let data = keychain.readGenericPassword(service: service) else { return nil }
        return ClaudeKeychain.parseCredentials(fromData: data)
    }
}
