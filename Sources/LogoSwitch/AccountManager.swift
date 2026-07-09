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
/// The outcome of `AccountManager.addSystemDefaultAccount()` (#56) — the switcher
/// can distinguish a fresh add from the expected idempotent already-exists.
public enum AddSystemDefaultResult: Sendable {
    case added(Account)
    case alreadyExists(Account)
    /// #56 verify B4: registry persistence failed — the account is NOT durably
    /// registered and no active id was written. Carries the error description.
    case failed(String)
}

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
        ensureDirectory: @escaping (String) throws -> Void = AccountManager.defaultEnsureDirectory
    ) {
        self.registry = registry ?? AccountRegistry(legacyDefaults: .standard)
        self.store = store ?? UserDefaultsActiveAccountStore()
        self.ensureDirectory = ensureDirectory
        self.activeAccountId = self.store.loadActiveAccountId()
        // #56 verify B3/C1: distinguish a DANGLING stored id from a FRESH (never-set) one.
        // - Dangling (e.g. after the system-default's id migrated UUID→fixed, leaving the
        //   stored id unresolvable) heals to the system-default — NOT accounts.first — and
        //   persists the correction so it doesn't recur.
        // - Fresh keeps the historical accounts.first seed, in-memory only (never persist a
        //   selection the user never made — that was an unintended round-1 behavior change).
        if let stored = self.activeAccountId {
            // #58: heal fires for a DANGLING stored id (unresolvable) OR one whose
            // ownership was reassigned by the registry's load-time repair — the
            // latter still resolves, but to a DIFFERENT logical account, so keeping
            // it would silently swap the identity that seeds new windows'
            // CLAUDE_CONFIG_DIR. Deterministic recovery (system-default first) is
            // applied even if the stale id happens to resolve "correctly" — which
            // account the user meant is unknowable after a corruption repair.
            if active == nil || self.registry.reassignedIDs.contains(stored) {
                let healed = accounts.first(where: { $0.isSystemDefault }) ?? accounts.first
                self.activeAccountId = healed?.id
                // #57 F4: persist the correction ONLY when the registry's normalize repair
                // actually persisted — else the store would point at an id the on-disk
                // index doesn't hold.
                if let id = healed?.id, self.registry.normalizeDidPersist {
                    self.store.saveActiveAccountId(id)
                }
            }
        } else {
            self.activeAccountId = accounts.first?.id
        }
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
        // #56 verify B1: isolated labels collide only with other ISOLATED accounts —
        // a system-default may share the label (its identity is its fixed id, not label).
        if accounts.contains(where: { !$0.isSystemDefault && $0.label == trimmed }) {
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
    @discardableResult
    public func addSystemDefaultAccount() -> AddSystemDefaultResult {
        // #56: the system-default is identified by its fixed id; already-exists is
        // expected idempotence, returned as a first-class result (not a logged error)
        // so the switcher can react. Uniqueness is by `isSystemDefault`, not label.
        if let existing = accounts.first(where: { $0.isSystemDefault }) {
            return .alreadyExists(existing)
        }
        let account = Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true)
        do {
            try registry.add(account)
        } catch {
            // #56 verify B4 (ensemble #4): a persist (disk) failure means the account is
            // NOT durably registered — return .failed WITHOUT touching active, so we
            // never write a dangling active id or mislead the caller with .added.
            LogoSwitchLog.account.notice("addSystemDefaultAccount persist failed — \(error.localizedDescription, privacy: .private)")
            return .failed(error.localizedDescription)
        }
        if activeAccountId == nil {
            activeAccountId = account.id
            store.saveActiveAccountId(account.id)
        }
        LogoSwitchLog.account.notice("added system-default account — id=\(account.id, privacy: .private)")
        return .added(account)
    }

    /// Remove an account. #57 verify A: launcher-local state (the live-401 flag,
    /// the active selection) is updated ONLY when the registry removal actually
    /// persisted — a failed persist rolls the registry back, so the account is
    /// still alive and nothing here may be cleared. Returns whether it happened.
    @discardableResult
    public func remove(accountId: String) -> Bool {
        do {
            try registry.remove(accountId: accountId)
        } catch {
            LogoSwitchLog.account.notice("remove not applied — registry persist failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
        forcedReauthIds.remove(accountId)   // bug #7: never leak a dead id
        if activeAccountId == accountId {
            activeAccountId = accounts.first?.id
            store.saveActiveAccountId(activeAccountId)
        }
        return true
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

    /// The production-default `ensureDirectory`: create the per-account config-dir
    /// chain (`~/.logos/accounts/<id>/.claude`) and leave it at restrictive `0o700`.
    ///
    /// #63 (defense-in-depth atop #61's accounts-root `0o700`): the create-time
    /// `attributes:` hardens the `<id>` + `.claude` dirs THIS call materializes, but
    /// is a no-op on an already-existing dir — so a best-effort post-create
    /// `setAttributes` re-chmods a pre-existing `0o755` leaf AND its `<id>`
    /// intermediate to `0o700`, converging them on the next call (mirrors
    /// `AccountRegistry.save()`'s create-attributes + post-write `setAttributes`).
    /// The `createDirectory` throw stays the spawn gate (bug #6); a chmod failure is
    /// logged, never thrown — degrading defense-in-depth, not create/switch.
    /// `@usableFromInline` so the public `init`'s default argument can name it
    /// without exposing it as public API; reachable in tests via `@testable`.
    @usableFromInline
    nonisolated static func defaultEnsureDirectory(_ path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Converge a pre-existing looser dir: the leaf and its `<id>` intermediate
        // (the parent). #61 hardens the accounts root above them; do not walk higher.
        //
        // Caveat: setAttributes(_:ofItemAtPath:) is chmod(2), which FOLLOWS symlinks —
        // were `dir` a symlink, this would re-mode its target, not the link itself.
        // Acceptable here: #61 creates and re-hardens the accounts root
        // (`~/.logos/accounts`) to 0o700 (owner-only) on every AccountRegistry.save(),
        // so no other-user can traverse into this chain to plant a symlink at `<id>`
        // or `<id>/.claude`; the only writer is the same-trust-domain owner.
        for dir in [path, (path as NSString).deletingLastPathComponent] {
            do {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            } catch {
                LogoSwitchLog.account.notice("config-dir permission set failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
