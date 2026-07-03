import Foundation
import Observation
import LogosAccounts

/// The launcher's account model: active selection, the live-401 re-auth nudge,
/// and config-dir materialization — and nothing more. The account LIST
/// (create/rename/remove/persist) is delegated to the shared `AccountRegistry`
/// (merge-multistats-into-logos), so the Logos app and the standalone viewer
/// observe one authoritative list. It never reads, copies, stores, probes, or
/// migrates a credential. Auth — login, the token, "am I logged in" — is
/// **claude's own job**, managed in claude's own terminal (#34). Logos only
/// OBSERVES a live 401 from the terminal to surface a non-blocking "needs
/// login" nudge (#31); it persists no auth state.
@Observable
@MainActor
public final class AccountManager {

    @ObservationIgnored private let registry: AccountRegistry
    @ObservationIgnored private let store: ActiveAccountStore
    /// Promptless directory creator (ensures a per-account config dir exists
    /// without writing credentials) — injected so the logic is unit-testable.
    @ObservationIgnored private let ensureDirectory: (String) throws -> Void

    /// The shared registry's list. Computed so SwiftUI observation flows
    /// through the `@Observable` registry — the switcher recomputes when any
    /// process-local mutation lands.
    public var accounts: [Account] { registry.accounts }

    /// The default account a NEWLY-opened window seeds from (#42). Logos windows are
    /// per-account (`WindowAccountSelection`), so this is no longer "the" active account
    /// — it's the seed for new windows and the highlight in the Settings→Accounts tab.
    /// Set via `setActive` (Settings / create); an in-window switch is window-local and
    /// does NOT write here. Persisted app-locally — "Active selection stays out
    /// of the shared registry".
    public private(set) var activeAccountId: String?

    /// Live re-auth signal (#31): set when the hosted claude reports a 401 this
    /// session; cleared when re-auth is initiated (#17 authorize URL), the banner
    /// is dismissed, or the account is switched away (#2). Session-VOLATILE — never
    /// persisted, never probed (a 401 is session-specific; auth state is claude's).
    /// Observed (no `@ObservationIgnored`) so the switcher recomputes on a flip.
    ///
    /// **Account-keyed, not window-keyed — by design (#44).** With per-window accounts
    /// (#42), two windows showing the SAME account share this 401 state (a 401 in one
    /// flags the account in the other's switcher; a dismiss in one clears both). That is
    /// correct: same account = same `CLAUDE_CONFIG_DIR` = the same claude session, so the
    /// auth state genuinely IS shared. Per-window 401 was considered and rejected — it
    /// would re-open the #30/#31 banner↔switcher coherence surface `AuthCoordinator` + the
    /// account-keyed set were built to close.
    private var forcedReauthIds: Set<String> = []

    public var active: Account? {
        guard let id = activeAccountId else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    /// - Parameters:
    ///   - registry: the shared account registry. nil → the production default
    ///     (shared index file, with one-time migration from this app's legacy
    ///     `logos.accounts` UserDefaults data).
    ///   - store: active-selection persistence. nil → production UserDefaults.
    public init(
        registry: AccountRegistry? = nil,
        store: ActiveAccountStore? = nil,
        ensureDirectory: @escaping (String) throws -> Void = {
            try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true)
        }
    ) {
        self.registry = registry ?? AccountRegistry(legacyDefaults: .standard)
        self.store = store ?? UserDefaultsActiveAccountStore()
        self.ensureDirectory = ensureDirectory
        self.activeAccountId = self.store.loadActiveAccountId()
        if active == nil, let first = accounts.first { self.activeAccountId = first.id }
    }

    // MARK: - Create / Remove / Rename (delegated to the shared registry)

    /// Create a new EMPTY account (no credential capture — #34). Creates its
    /// `CLAUDE_CONFIG_DIR` target dir BEFORE registering, so a directory
    /// failure gates creation (bug #6 spirit) and never leaves a
    /// registered-but-dirless account. The user signs in by running `/login`
    /// in the hosted claude for it (claude opens its own browser).
    @discardableResult
    public func createAccount(label: String) throws -> Account {
        let trimmed = try Account.validate(label: label)
        if accounts.contains(where: { $0.label == trimmed }) {
            throw Account.ValidationError.duplicateLabel
        }
        let account = Account(label: trimmed)
        try ensureDirectory(account.configDirPath)
        try registry.add(account)
        if activeAccountId == nil {
            activeAccountId = account.id
            store.saveActiveAccountId(account.id)
        }
        return account
    }

    /// Register the single "main" system-default account (#54): it reuses the
    /// system `~/.claude` login (spawns with `configDir == nil`, materializes no
    /// config dir) instead of an isolated per-account dir. Dedup-guarded — a
    /// second call is a no-op. First-party-safe: touches no credential, it just
    /// declines to isolate this one account.
    public func addSystemDefaultAccount() {
        guard !accounts.contains(where: { $0.isSystemDefault }) else { return }
        let account = Account(label: "Main", isSystemDefault: true)
        do {
            try registry.add(account)
        } catch {
            // e.g. a pre-existing isolated account already named "Main"
            // (registry.add validates + dedups label) — surface it, don't
            // silently swallow.
            // #54 verify (Finding 7): .private — localizedDescription may echo a user account label.
            LogoSwitchLog.account.notice("addSystemDefaultAccount skipped — \(error.localizedDescription, privacy: .private)")
            return
        }
        if activeAccountId == nil {
            activeAccountId = account.id
            store.saveActiveAccountId(account.id)
        }
        LogoSwitchLog.account.notice("added system-default account — id=\(account.id, privacy: .private)")
    }

    public func remove(accountId: String) {
        registry.remove(accountId: accountId)
        forcedReauthIds.remove(accountId)   // bug #7: never leak a dead id
        if activeAccountId == accountId {
            activeAccountId = accounts.first?.id
            store.saveActiveAccountId(activeAccountId)
        }
    }

    /// Rename `accountId`'s label. Pure registry metadata — the account **id**
    /// (the `CLAUDE_CONFIG_DIR` key) and `createdAt` are preserved, so a rename
    /// never moves the config dir, invalidates a login, or touches credentials
    /// (#34). Validation (non-empty, ≤30, no duplicate of ANOTHER account) is
    /// the registry's.
    public func rename(accountId: String, to newLabel: String) throws {
        try registry.rename(accountId: accountId, to: newLabel)
    }

    // MARK: - Switch active

    /// Switch the active account. Purely local state (#12): each account's claude
    /// credentials live under its own `CLAUDE_CONFIG_DIR` keychain item, so there
    /// is nothing to swap — NO keychain read/write, and NO shared-index write
    /// (the selection is app-local).
    public func setActive(_ accountId: String) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        // bug #2: a live-401 force was specific to the prior account's spawn —
        // clear it on switch-away so it doesn't stay pinned needs-login forever.
        if let prior = activeAccountId, prior != accountId {
            forcedReauthIds.remove(prior)
        }
        activeAccountId = accountId
        store.saveActiveAccountId(accountId)
        // Account id is identifying — keep it `.private` (#22 D3).
        LogoSwitchLog.account.notice("active account set — id=\(accountId, privacy: .private)")
    }

    /// #27 UI-testing seed: append stub accounts (no credentials) so a fresh
    /// XCUITest launch has a renderable terminal + ≥1 switchable account.
    /// Inert in production (the UI-testing registry points at a per-launch
    /// temp index).
    public func seedAccounts(_ labels: [String]) {
        for label in labels where !accounts.contains(where: { $0.label == label }) {
            let account = Account(label: label)
            try? ensureDirectory(account.configDirPath)
            try? registry.add(account)
        }
        if active == nil, let first = accounts.first { activeAccountId = first.id }
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
        // #54: the system-default account reuses the real ~/.claude — never
        // mkdir over it (and #21: HOME is never overridden either).
        guard !account.isSystemDefault else {
            LogoSwitchLog.account.notice("system-default account — skipping config-dir materialization (reuses ~/.claude)")
            return
        }
        try ensureDirectory(account.configDirPath)
        LogoSwitchLog.account.notice("materialized config dir — account=\(account.id, privacy: .private)")
    }
}
