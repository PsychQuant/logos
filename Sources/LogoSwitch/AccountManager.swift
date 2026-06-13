import Foundation
import Observation

/// Owns the account list + per-account isolation + promptless re-auth state
/// (#12/#31/#34). A LAUNCHER's account model: it never reads, copies, decrypts,
/// or stores a credential — claude manages each account's token under its own
/// `CLAUDE_CONFIG_DIR` keychain item (set at spawn by `ClaudeProcessConfig`). New
/// accounts are empty labels; the user authenticates each via `claude auth login`
/// (`ClaudeAuthInvoker`), which opens claude's own browser. Persistence is
/// delegated to `AccountStore` (legacy-key compatible).
@Observable
@MainActor
public final class AccountManager {

    @ObservationIgnored private let store: AccountStore
    /// Promptless filesystem probe for a path's existence — injected so the
    /// needs-reauth / migration logic is unit-testable without the real FS.
    @ObservationIgnored private let fileExists: (String) -> Bool
    /// Promptless directory creator (ensures per-account config dirs exist without
    /// writing any credentials) — injected for the same reason.
    @ObservationIgnored private let ensureDirectory: (String) throws -> Void
    @ObservationIgnored private var migrated = false

    public private(set) var accounts: [Account] = []
    public private(set) var activeAccountId: String?
    /// Logos's OWN promptless authenticated signal (#12) — never reads the system
    /// Keychain to decide needs-reauth. Best-effort: may drift if the user logs
    /// in/out outside Logos.
    public private(set) var authenticatedAccountIds: Set<String> = []
    /// Live re-auth override (#31). When the terminal emits a live 401 the
    /// Coordinator forces the active account to read needs-reauth so the switcher
    /// agrees with the banner. Session-VOLATILE: never persisted (a 401 is
    /// session-specific — a prior session must not force-reauth a fresh launch).
    /// Observed (no `@ObservationIgnored`) so the switcher recomputes on flip.
    private var forcedReauthIds: Set<String> = []

    public var active: Account? {
        guard let id = activeAccountId else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    public init(
        store: AccountStore = UserDefaultsAccountStore(),
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        ensureDirectory: @escaping (String) throws -> Void = {
            try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true)
        }
    ) {
        self.store = store
        self.fileExists = fileExists
        self.ensureDirectory = ensureDirectory
        let index = store.load()
        self.accounts = index.accounts
        self.activeAccountId = index.activeAccountId
        self.authenticatedAccountIds = Set(index.authenticatedAccountIds)
        self.migrated = index.migrated
        if active == nil, let first = accounts.first { self.activeAccountId = first.id }
    }

    // MARK: - Create / Remove

    /// Create a new EMPTY account (no credential capture — the #34 launcher model
    /// replaces the old "capture current login" flow). Creates the account's
    /// `CLAUDE_CONFIG_DIR` target dir; the user then authenticates via
    /// `claude auth login` under it (claude opens its own browser).
    @discardableResult
    public func createAccount(label: String) throws -> Account {
        let trimmed = try Account.validate(label: label)
        if accounts.contains(where: { $0.label == trimmed }) {
            throw Account.ValidationError.duplicateLabel
        }
        let account = Account(label: trimmed)
        try ensureDirectory(account.configDirPath)
        accounts.append(account)
        if activeAccountId == nil { activeAccountId = account.id }
        persist()
        return account
    }

    public func remove(accountId: String) {
        accounts.removeAll { $0.id == accountId }
        authenticatedAccountIds.remove(accountId)
        forcedReauthIds.remove(accountId)   // bug #7: never leak a dead id in the override set
        if activeAccountId == accountId {
            activeAccountId = accounts.first?.id
        }
        persist()
    }

    // MARK: - Switch active

    /// Switch the active account. Purely local state (#12): each account's claude
    /// credentials live under its own `CLAUDE_CONFIG_DIR` keychain item, so there
    /// is nothing to swap — NO keychain read/write (the cross-identity `SecItem`
    /// write that triggers the macOS "找不到鑰匙圈" dialog never happens).
    public func setActive(_ accountId: String) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        // bug #2: a live-401 force is specific to the prior account's spawn —
        // clear it for the account being switched AWAY from, so it doesn't stay
        // pinned needs-reauth in the switcher forever.
        if let prior = activeAccountId, prior != accountId {
            forcedReauthIds.remove(prior)
        }
        activeAccountId = accountId
        persist()
        // Account id is identifying — keep it `.private` (#22 D3).
        LogoSwitchLog.account.notice("active account set — id=\(accountId, privacy: .private)")
    }

    /// #27 UI-testing seed: append in-memory stub accounts (no credentials) so a
    /// fresh XCUITest launch has a renderable terminal + ≥1 switchable account.
    /// Persists to whatever store was injected (LogosApp injects a volatile suite
    /// under `--ui-testing`). Inert in production.
    public func seedAccounts(_ labels: [String]) {
        for label in labels where !accounts.contains(where: { $0.label == label }) {
            let account = Account(label: label)
            accounts.append(account)
            try? ensureDirectory(account.configDirPath)
            authenticatedAccountIds.insert(account.id)
        }
        if active == nil { activeAccountId = accounts.first?.id }
        persist()
        LogoSwitchLog.account.notice("seeded UI-testing accounts — count=\(self.accounts.count, privacy: .public)")
    }

    // MARK: - Authentication state (needs-reauth, promptless — #12)

    /// Path of claude's file-based credential fallback for `account`. PRIVATE — the
    /// path never leaves the module (existence-probe only; never read).
    private func credentialsFilePath(for account: Account) -> String {
        "\(account.configDirPath)/.credentials.json"
    }

    /// Whether `account` should be surfaced as needing re-authentication, from
    /// promptless signals ONLY (#12): the live-401 override (#31) forces true;
    /// otherwise false when Logos's authenticated flag is set or a
    /// `.credentials.json` exists in the account's config dir; else true. Never
    /// reads the system Keychain.
    public func needsReauth(_ account: Account) -> Bool {
        if forcedReauthIds.contains(account.id) { return true }      // #31 live-401 override
        if authenticatedAccountIds.contains(account.id) { return false }
        if fileExists(credentialsFilePath(for: account)) { return false }
        return true
    }

    /// Force `accountId` needs-reauth after a live 401 (#31). Guarded by
    /// `accounts.contains` (bug #7) so a stale id can't enter the override set.
    public func forceReauth(_ accountId: String) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        forcedReauthIds.insert(accountId)
    }

    /// Clear the live-401 override — re-auth was INITIATED (a new authorize URL
    /// appeared), so the static signals govern again (#31).
    public func clearForcedReauth(_ accountId: String) {
        forcedReauthIds.remove(accountId)
    }

    /// The user DISMISSED the re-auth banner (bug #4). Treat it as acknowledging
    /// the session: clear the live-401 override too, so the banner and the
    /// switcher (both derived from `needsReauth`) stay coherent — the old dismiss
    /// cleared only the banner flag, leaving the switcher pinned.
    public func acknowledgeReauth(_ accountId: String) {
        forcedReauthIds.remove(accountId)
    }

    /// Record that `accountId` is authenticated (e.g. after a successful
    /// `claude auth login` under its config dir). Touches no Keychain.
    public func markAuthenticated(_ accountId: String) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        authenticatedAccountIds.insert(accountId)
        persist()
    }

    /// Clear the authenticated flag for `accountId` (force needs-reauth).
    public func markNeedsReauth(_ accountId: String) {
        guard authenticatedAccountIds.contains(accountId) else { return }
        authenticatedAccountIds.remove(accountId)
        persist()
    }

    // MARK: - Migration to isolated credentials (#12)

    /// One-time, idempotent, non-destructive migration: ensure each account's
    /// config dir exists and mark it needs-reauth unless a `.credentials.json`
    /// signal is already present. Never touches the system Keychain.
    public func migrateToIsolatedCredentialsIfNeeded() {
        guard !migrated else { return }
        LogoSwitchLog.account.notice("migrating to isolated credentials — accounts=\(self.accounts.count, privacy: .public)")
        for account in accounts {
            try? ensureDirectory(account.configDirPath)
            if !fileExists(credentialsFilePath(for: account)) {
                authenticatedAccountIds.remove(account.id)
            }
        }
        migrated = true
        persist()
    }

    // MARK: - Per-account config dir (the CLAUDE_CONFIG_DIR target)

    /// Create the per-account `.claude` dir (`~/.logos/accounts/<id>/.claude`) —
    /// the `CLAUDE_CONFIG_DIR` target that isolates each account (#12). Routed
    /// through the injected `ensureDirectory` so a failure is testable + can gate
    /// the spawn (bug #6). Writes no credentials. #21: HOME is never overridden.
    public func materializeHomeTree(for account: Account) throws {
        try ensureDirectory(account.configDirPath)
        // Account id is identifying — keep it `.private`; the path is never logged (#22 D3).
        LogoSwitchLog.account.notice("materialized config dir — account=\(account.id, privacy: .private)")
    }

    // MARK: - Persistence

    private func persist() {
        store.save(AccountIndex(
            accounts: accounts,
            activeAccountId: activeAccountId,
            authenticatedAccountIds: Array(authenticatedAccountIds),
            migrated: migrated
        ))
    }
}
