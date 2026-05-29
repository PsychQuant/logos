import Foundation
import Observation

@Observable
@MainActor
public final class AccountManager {

    @ObservationIgnored private let store: AccountCredentialStore
    @ObservationIgnored private let systemBridge: SystemKeychainBridge
    @ObservationIgnored private let defaults: UserDefaults
    /// Promptless filesystem probe for a path's existence. Injected so the
    /// needs-reauth / migration logic is unit-testable without touching the real
    /// filesystem. Defaults to the real `FileManager`.
    @ObservationIgnored private let fileExists: (String) -> Bool
    /// Promptless directory creator (migration ensures per-account config dirs
    /// exist without writing any credentials). Injected for the same reason.
    @ObservationIgnored private let ensureDirectory: (String) throws -> Void

    private enum DefaultsKey {
        static let accounts = "logos.accounts"
        static let activeId = "logos.accounts.activeId"
        static let authenticatedIds = "logos.accounts.authenticatedIds"
        static let migratedIsolated = "logos.accounts.migratedIsolatedCredentials"
    }

    public private(set) var accounts: [Account] = []
    public private(set) var activeAccountId: String?
    /// Ids of accounts Logos considers authenticated. This is Logos's OWN
    /// promptless signal (#12) — Logos never reads the system Keychain to decide
    /// needs-reauth. Best-effort: may drift if the user logs in/out outside Logos.
    public private(set) var authenticatedAccountIds: Set<String> = []

    public var active: Account? {
        guard let id = activeAccountId else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    public init(
        store: AccountCredentialStore,
        systemBridge: SystemKeychainBridge = RealSystemKeychainBridge(),
        defaults: UserDefaults = .standard,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        ensureDirectory: @escaping (String) throws -> Void = {
            try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true)
        }
    ) {
        self.store = store
        self.systemBridge = systemBridge
        self.defaults = defaults
        self.fileExists = fileExists
        self.ensureDirectory = ensureDirectory
        loadFromDefaults()
    }

    // MARK: - Add / Remove

    /// Original "add by raw blob" — kept for tests and explicit-import flows.
    public func add(label: String, credentials: Data) throws {
        let trimmed = try Account.validate(label: label)
        if accounts.contains(where: { $0.label == trimmed }) {
            throw Account.ValidationError.duplicateLabel
        }
        let account = Account(label: trimmed)
        try store.save(accountId: account.id, credentials: credentials)
        accounts.append(account)
        if activeAccountId == nil {
            // First account becomes active immediately. No system-Keychain write
            // (#12): activation is local state only; claude reads each account's
            // credentials from its own per-`CLAUDE_CONFIG_DIR` entry at spawn time.
            activeAccountId = account.id
        }
        persistToDefaults()
    }

    /// E.2: Capture the CURRENT system Claude credentials and save as a new
    /// Logos account. This is the primary way to add accounts in v1.
    ///
    /// Flow: user runs `claude login` (or already logged in) → opens Logos →
    /// "Add account: work" → Logos reads system Keychain → saves as work.
    public func addByCapturingCurrent(label: String) throws {
        guard let data = try systemBridge.read() else {
            throw AddByCaptureError.noSystemCredentials
        }
        try add(label: label, credentials: data)
    }

    public enum AddByCaptureError: Error, Equatable {
        case noSystemCredentials
    }

    public func remove(accountId: String) throws {
        // store.delete removes Logos's OWN per-account backup (service
        // "app.getlogos.logos.credentials"), not the shared system entry.
        try store.delete(accountId: accountId)
        accounts.removeAll { $0.id == accountId }
        if activeAccountId == accountId {
            // Reassign active locally only. No system-Keychain swap (#12): the
            // newly-active account reads its own per-`CLAUDE_CONFIG_DIR`
            // credentials at spawn time. claude's per-account entries and the
            // shared bare entry are never written or deleted by Logos.
            activeAccountId = accounts.first?.id
        }
        persistToDefaults()
    }

    // MARK: - Switch active

    /// Switch the active account. With per-account credential isolation (#12),
    /// switching is purely local state: each account's claude credentials live in
    /// claude's own per-`CLAUDE_CONFIG_DIR` Keychain item (set at spawn time by
    /// `ClaudeProcessConfig`), so there is nothing to swap in the shared system
    /// Keychain. This method performs NO Keychain read or write, which is what
    /// eliminates the cross-identity `SecItem` write that could trigger the
    /// macOS "找不到鑰匙圈" reset dialog.
    public func setActive(_ accountId: String) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        activeAccountId = accountId
        persistToDefaults()
    }

    /// Re-capture current system Claude credentials into the currently-active
    /// account. Useful if you suspect claude refreshed tokens recently.
    public func captureCurrentIntoActive() throws {
        guard let activeId = activeAccountId else { return }
        guard let data = try systemBridge.read() else { return }
        try store.save(accountId: activeId, credentials: data)
    }

    // MARK: - Authentication state (needs-reauth, promptless — #12)

    /// Path of claude's file-based credential fallback for `account`.
    private func credentialsFilePath(for account: Account) -> String {
        "\(account.configDirPath)/.credentials.json"
    }

    /// Whether `account` should be surfaced as needing re-authentication. Uses
    /// ONLY promptless signals (#12): true UNLESS Logos's own authenticated flag
    /// is set OR a `.credentials.json` file exists in the account's config dir.
    /// Never reads the system Keychain — a cross-identity read can surface an
    /// access prompt and re-couples Logos to the keychain this change removes.
    public func needsReauth(_ account: Account) -> Bool {
        if authenticatedAccountIds.contains(account.id) { return false }
        if fileExists(credentialsFilePath(for: account)) { return false }
        return true
    }

    /// Record that `accountId` is authenticated (e.g. after the user completes
    /// `claude login` under its config dir). Does not touch the Keychain.
    public func markAuthenticated(_ accountId: String) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        authenticatedAccountIds.insert(accountId)
        persistToDefaults()
    }

    /// Clear the authenticated flag for `accountId` (force needs-reauth).
    public func markNeedsReauth(_ accountId: String) {
        guard authenticatedAccountIds.contains(accountId) else { return }
        authenticatedAccountIds.remove(accountId)
        persistToDefaults()
    }

    // MARK: - Migration to isolated credentials (#12)

    /// One-time, idempotent, NON-DESTRUCTIVE migration to the isolated-credential
    /// model. For each existing account: ensures its config dir exists (no
    /// credentials written) and marks it needs-reauth unless a promptless
    /// credential signal (`.credentials.json`) is already present. Never writes
    /// or deletes the system Keychain or the bare `Claude Code-credentials` entry.
    public func migrateToIsolatedCredentialsIfNeeded() {
        guard !defaults.bool(forKey: DefaultsKey.migratedIsolated) else { return }
        for account in accounts {
            try? ensureDirectory(account.configDirPath)
            if !fileExists(credentialsFilePath(for: account)) {
                authenticatedAccountIds.remove(account.id)
            }
        }
        defaults.set(true, forKey: DefaultsKey.migratedIsolated)
        persistToDefaults()
    }

    // MARK: - HOME tree (deprecated for credentials; kept for per-account history)

    /// Create per-account HOME tree at ~/.logos/accounts/<id>/.
    /// E.2: No longer writes .credentials.json (claude reads Keychain, not file).
    /// Still useful for per-account history isolation if HOME env override is used.
    public func materializeHomeTree(for account: Account) throws {
        let fm = FileManager.default
        let homePath = account.homeDirectoryPath
        let claudePath = "\(homePath)/.claude"
        try fm.createDirectory(atPath: claudePath, withIntermediateDirectories: true)
        // E.2: no longer writes .credentials.json. claude reads system Keychain.
    }

    private func loadFromDefaults() {
        if let data = defaults.data(forKey: DefaultsKey.accounts),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            self.accounts = decoded
        }
        self.activeAccountId = defaults.string(forKey: DefaultsKey.activeId)
        if active == nil, let first = accounts.first {
            self.activeAccountId = first.id
        }
        if let ids = defaults.array(forKey: DefaultsKey.authenticatedIds) as? [String] {
            self.authenticatedAccountIds = Set(ids)
        }
    }

    private func persistToDefaults() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: DefaultsKey.accounts)
        }
        if let id = activeAccountId {
            defaults.set(id, forKey: DefaultsKey.activeId)
        } else {
            defaults.removeObject(forKey: DefaultsKey.activeId)
        }
        defaults.set(Array(authenticatedAccountIds), forKey: DefaultsKey.authenticatedIds)
    }
}
