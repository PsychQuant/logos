import Foundation

/// A discovered Claude Code account — the default `~/.claude` or a Logos
/// per-account config dir (`~/.logos/accounts/<uuid>/.claude`).
public struct Account: Identifiable, Equatable, Sendable {
    public let id: String
    public let configDir: URL
    public let isDefault: Bool
    public let identity: AccountIdentity?

    public init(configDir: URL, isDefault: Bool, identity: AccountIdentity?) {
        let standardized = configDir.standardizedFileURL
        self.configDir = standardized
        self.id = standardized.path
        self.isDefault = isDefault
        self.identity = identity
    }

    /// Best human-readable label for UI: display name, else email, else dir name.
    public var label: String {
        identity?.displayName ?? identity?.emailAddress ?? configDir.deletingLastPathComponent().lastPathComponent
    }
}

/// Subset of the `oauthAccount` object in Claude Code's top-level config JSON.
/// Every field is optional — the file is an undocumented internal format and
/// absent keys must never fail the whole account.
public struct AccountIdentity: Equatable, Sendable, Decodable {
    public let accountUuid: String?
    public let displayName: String?
    public let emailAddress: String?
    public let organizationName: String?
    public let userRateLimitTier: String?
    public let organizationRateLimitTier: String?
    public let billingType: String?
    public let seatTier: String?

    public init(
        accountUuid: String? = nil,
        displayName: String? = nil,
        emailAddress: String? = nil,
        organizationName: String? = nil,
        userRateLimitTier: String? = nil,
        organizationRateLimitTier: String? = nil,
        billingType: String? = nil,
        seatTier: String? = nil
    ) {
        self.accountUuid = accountUuid
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.organizationName = organizationName
        self.userRateLimitTier = userRateLimitTier
        self.organizationRateLimitTier = organizationRateLimitTier
        self.billingType = billingType
        self.seatTier = seatTier
    }
}
