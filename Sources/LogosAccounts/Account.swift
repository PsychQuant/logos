import Foundation

public struct Account: Identifiable, Hashable, Sendable, Codable {

    /// The stable, well-known id of the system-default ("main") account (#56).
    /// Registry uniqueness for the system-default keys off this id, NOT the
    /// mutable label — so a "Main" system-default coexists with an isolated
    /// "Main". Safe as a fixed id because the system-default's `spawnConfigDir`
    /// is nil, so the id is never used as a spawn config-dir path for it.
    public static let systemDefaultID = "system-default"

    /// Stable per-account identifier. Used as the per-account **config-dir** name
    /// (the `CLAUDE_CONFIG_DIR` target), NOT the process `HOME` — Logos never
    /// overrides `HOME` (PsychQuant/logos#21), since that would move the login
    /// keychain lookup and break claude's credential read.
    public let id: String
    public let label: String  // user-visible name; editable
    public let createdAt: Date

    /// When true, this is the "main" account that reuses the system `~/.claude`
    /// login: it spawns claude with NO `CLAUDE_CONFIG_DIR` override
    /// (`spawnConfigDir == nil`), so claude falls through to the default
    /// `~/.claude` + the bare `Claude Code-credentials` keychain entry. Zero
    /// token touch — Logos never reads a credential; it just declines to isolate
    /// this one account (PsychQuant/logos#54).
    public let isSystemDefault: Bool

    public init(
        id: String = UUID().uuidString,
        label: String,
        createdAt: Date = Date(),
        isSystemDefault: Bool = false
    ) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespaces)
        self.createdAt = createdAt
        self.isSystemDefault = isSystemDefault
    }

    /// Custom decode so accounts persisted before `isSystemDefault` existed (no
    /// such key) decode as `false` rather than throwing (#54). `encode(to:)`
    /// stays synthesized — it uses the same `CodingKeys` and emits all four fields.
    enum CodingKeys: String, CodingKey {
        case id, label, createdAt, isSystemDefault
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.isSystemDefault = try c.decodeIfPresent(Bool.self, forKey: .isSystemDefault) ?? false
    }

    /// The account's Logos-internal data directory (`~/.logos/accounts/<id>`).
    /// This is the parent of the claude config dir — it is NOT the process `HOME`
    /// (#21); the spawned claude inherits the real `HOME` and only its
    /// `CLAUDE_CONFIG_DIR` points here.
    public var homeDirectoryPath: String {
        AccountsRoot.url().appendingPathComponent(id).path
    }

    /// Per-account claude config directory. claude keys its credential Keychain
    /// service name on this directory (service `Claude Code-credentials-<hash>`,
    /// where `<hash>` is the first 8 hex chars of `sha256` over the NFC-normalized
    /// path), so giving each account its own config dir isolates its credentials
    /// into claude's own per-directory Keychain item — Logos never writes the
    /// shared `Claude Code-credentials` entry (PsychQuant/logos#12).
    public var configDirPath: String {
        "\(homeDirectoryPath)/.claude"
    }

    /// The config dir to spawn claude with. `nil` for a system-default account
    /// (#54) → `ClaudeConfigEnvironment.apply` sets no `CLAUDE_CONFIG_DIR`, so
    /// claude uses the system `~/.claude`. For an isolated account it is
    /// `configDirPath`. `configDirPath` itself stays non-optional — it is still
    /// the `materializeHomeTree` mkdir target for isolated accounts.
    public var spawnConfigDir: String? {
        isSystemDefault ? nil : configDirPath
    }

    public enum ValidationError: Error, Equatable {
        case emptyLabel
        case labelTooLong
        case duplicateLabel
        /// #57 F1: an account with this id already exists (global id-uniqueness).
        case duplicateID
        /// #57 F2: a system-default account already exists (at most one).
        case duplicateSystemDefault
        /// #57 round-2: reserved-id ownership — the fixed `systemDefaultID` may
        /// only (and must only) be held by the system-default account.
        case reservedID
    }

    /// Validate label only (duplicate-check requires AccountManager).
    public static func validate(label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw ValidationError.emptyLabel }
        if trimmed.count > 30 { throw ValidationError.labelTooLong }
        return trimmed
    }
}
