import Foundation

public struct Account: Identifiable, Hashable, Sendable, Codable {

    /// Stable per-account identifier. Used as the per-account **config-dir** name
    /// (the `CLAUDE_CONFIG_DIR` target), NOT the process `HOME` — Logos never
    /// overrides `HOME` (PsychQuant/logos#21), since that would move the login
    /// keychain lookup and break claude's credential read.
    public let id: String
    public let label: String  // user-visible name; editable
    public let createdAt: Date

    public init(id: String = UUID().uuidString, label: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespaces)
        self.createdAt = createdAt
    }

    /// The account's Logos-internal data directory (`~/.logos/accounts/<id>`).
    /// This is the parent of the claude config dir — it is NOT the process `HOME`
    /// (#21); the spawned claude inherits the real `HOME` and only its
    /// `CLAUDE_CONFIG_DIR` points here.
    public var homeDirectoryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.logos/accounts/\(id)"
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

    public enum ValidationError: Error, Equatable {
        case emptyLabel
        case labelTooLong
        case duplicateLabel
    }

    /// Validate label only (duplicate-check requires AccountManager).
    public static func validate(label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw ValidationError.emptyLabel }
        if trimmed.count > 30 { throw ValidationError.labelTooLong }
        return trimmed
    }
}
