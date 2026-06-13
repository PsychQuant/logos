import Foundation
import Observation

/// Owns the account list + per-account `CLAUDE_CONFIG_DIR` isolation (#12) and the
/// active selection. The launcher's account model and nothing more: it never
/// reads, copies, stores, probes, or migrates a credential. Auth — login, the
/// token, "am I logged in" — is **claude's own job**, managed in claude's own
/// terminal (#34). Logos only OBSERVES a live 401 from the terminal to surface a
/// non-blocking "needs login" nudge (#31); it persists no auth state.
@Observable
@MainActor
public final class AccountManager {

    @ObservationIgnored private let store: AccountStore
    /// Promptless directory creator (ensures a per-account config dir exists
    /// without writing credentials) — injected so the logic is unit-testable.
    @ObservationIgnored private let ensureDirectory: (String) throws -> Void

    public private(set) var accounts: [Account] = []
    public private(set) var activeAccountId: String?
    /// Live re-auth signal (#31): set when the hosted claude reports a 401 this
    /// session; cleared when re-auth is initiated (#17 authorize URL), the banner
    /// is dismissed, or the account is switched away (#2). Session-VOLATILE — never
    /// persisted, never probed (a 401 is session-specific; auth state is claude's).
    /// Observed (no `@ObservationIgnored`) so the switcher recomputes on a flip.
    private var forcedReauthIds: Set<String> = []

    public var active: Account? {
        guard let id = activeAccountId else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    public init(
        store: AccountStore = UserDefaultsAccountStore(),
        ensureDirectory: @escaping (String) throws -> Void = {
            try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true)
        }
    ) {
        self.store = store
        self.ensureDirectory = ensureDirectory
        let index = store.load()
        self.accounts = index.accounts
        self.activeAccountId = index.activeAccountId
        if active == nil, let first = accounts.first { self.activeAccountId = first.id }
    }

    // MARK: - Create / Remove

    /// Create a new EMPTY account (no credential capture — #34). Creates its
    /// `CLAUDE_CONFIG_DIR` target dir; the user signs in by running `/login` in the
    /// hosted claude for it (claude opens its own browser).
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
        forcedReauthIds.remove(accountId)   // bug #7: never leak a dead id
        if activeAccountId == accountId {
            activeAccountId = accounts.first?.id
        }
        persist()
    }

    // MARK: - Switch active

    /// Switch the active account. Purely local state (#12): each account's claude
    /// credentials live under its own `CLAUDE_CONFIG_DIR` keychain item, so there
    /// is nothing to swap — NO keychain read/write.
    public func setActive(_ accountId: String) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        // bug #2: a live-401 force was specific to the prior account's spawn —
        // clear it on switch-away so it doesn't stay pinned needs-login forever.
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
    /// Inert in production.
    public func seedAccounts(_ labels: [String]) {
        for label in labels where !accounts.contains(where: { $0.label == label }) {
            let account = Account(label: label)
            accounts.append(account)
            try? ensureDirectory(account.configDirPath)
        }
        if active == nil { activeAccountId = accounts.first?.id }
        persist()
        LogoSwitchLog.account.notice("seeded UI-testing accounts — count=\(self.accounts.count, privacy: .public)")
    }

    // MARK: - Re-auth state (live-401 observation ONLY — #31)

    /// Whether to surface a "needs login" nudge for `account`. The ONLY signal is
    /// the live 401 the hosted claude reported this session — Logos reads no
    /// system Keychain, no `.credentials.json`, no persisted flag, and runs no
    /// `claude auth status` probe. Auth state is claude's; Logos just observes.
    public func needsReauth(_ account: Account) -> Bool {
        forcedReauthIds.contains(account.id)
    }

    /// Force `account` to read needs-login after a live 401 (#31). Guarded so a
    /// stale id can't enter the set (bug #7).
    public func forceReauth(_ accountId: String) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        forcedReauthIds.insert(accountId)
    }

    /// Clear the live-401 override — re-auth was INITIATED (a new authorize URL
    /// appeared in the terminal, #17/#31).
    public func clearForcedReauth(_ accountId: String) {
        forcedReauthIds.remove(accountId)
    }

    /// The user DISMISSED the re-auth banner (bug #4) — clear the override too so
    /// the banner and the switcher (both derived from `needsReauth`) stay coherent.
    public func acknowledgeReauth(_ accountId: String) {
        forcedReauthIds.remove(accountId)
    }

    // MARK: - Per-account config dir (the CLAUDE_CONFIG_DIR target)

    /// Create the per-account `.claude` dir (`~/.logos/accounts/<id>/.claude`) —
    /// the `CLAUDE_CONFIG_DIR` target that isolates each account (#12). Routed
    /// through the injected `ensureDirectory` so a failure is testable + can gate
    /// the spawn (bug #6). Writes no credentials. #21: HOME is never overridden.
    public func materializeHomeTree(for account: Account) throws {
        try ensureDirectory(account.configDirPath)
        LogoSwitchLog.account.notice("materialized config dir — account=\(account.id, privacy: .private)")
    }

    private func persist() {
        store.save(AccountIndex(accounts: accounts, activeAccountId: activeAccountId))
    }
}
