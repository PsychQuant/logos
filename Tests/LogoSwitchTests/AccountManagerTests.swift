import Testing
import Foundation
import LogoSwitch

@Suite("AccountManager", .serialized)
@MainActor
struct AccountManagerTests {

    private struct DirError: Error {}

    /// No real FS: `ensureDirectory` no-ops, `fileExists` false (so an account is
    /// needs-reauth unless explicitly marked). A shared `InMemoryAccountStore`
    /// stands in for persistence across manager instances.
    private func makeManager(
        store: AccountStore = InMemoryAccountStore(),
        fileExists: @escaping (String) -> Bool = { _ in false },
        ensureDirectory: @escaping (String) throws -> Void = { _ in }
    ) -> AccountManager {
        AccountManager(store: store, fileExists: fileExists, ensureDirectory: ensureDirectory)
    }

    @Test("starts empty")
    func startsEmpty() {
        let mgr = makeManager()
        #expect(mgr.accounts.isEmpty)
        #expect(mgr.active == nil)
    }

    @Test("createAccount adds a labeled empty account (no credential capture)")
    func createAccount() throws {
        let mgr = makeManager()
        let acc = try mgr.createAccount(label: "personal")
        #expect(mgr.accounts.count == 1)
        #expect(mgr.accounts[0].label == "personal")
        #expect(acc.label == "personal")
    }

    @Test("first created becomes active")
    func firstActive() throws {
        let mgr = makeManager()
        try mgr.createAccount(label: "p")
        #expect(mgr.active?.label == "p")
    }

    @Test("setActive changes selection")
    func switchActive() throws {
        let mgr = makeManager()
        try mgr.createAccount(label: "a")
        let b = try mgr.createAccount(label: "b")
        mgr.setActive(b.id)
        #expect(mgr.active?.label == "b")
    }

    @Test("duplicate label rejected")
    func duplicateLabel() throws {
        let mgr = makeManager()
        try mgr.createAccount(label: "x")
        #expect(throws: Account.ValidationError.duplicateLabel) {
            try mgr.createAccount(label: "x")
        }
    }

    @Test("remove reassigns active")
    func removeAccount() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "a")
        try mgr.createAccount(label: "b")
        mgr.remove(accountId: a.id)
        #expect(mgr.accounts.count == 1)
        #expect(mgr.active?.label == "b")
    }

    @Test("active persists across a fresh manager on the same store")
    func activePersists() throws {
        let store = InMemoryAccountStore()
        let mgr1 = makeManager(store: store)
        try mgr1.createAccount(label: "a")
        let b = try mgr1.createAccount(label: "b")
        mgr1.setActive(b.id)
        let mgr2 = makeManager(store: store)
        #expect(mgr2.activeAccountId == b.id)
    }

    @Test("materializeHomeTree routes through the injected ensureDirectory (no throw)")
    func materializeHomeTree() throws {
        let mgr = makeManager()
        let acc = try mgr.createAccount(label: "x")
        try mgr.materializeHomeTree(for: acc)   // no-op ensureDirectory → no throw
    }

    // bug #6: a config-dir creation failure must SURFACE (so the spawn gate can
    // block instead of launching into a phantom dir). Routed through the injected
    // ensureDirectory, which here throws.
    @Test("materializeHomeTree throws when the directory cannot be created (bug #6)")
    func materializeThrowsOnDirFailure() {
        let seeded = AccountIndex(accounts: [Account(id: "a", label: "a")], activeAccountId: "a")
        let mgr = AccountManager(
            store: InMemoryAccountStore(seeded),
            fileExists: { _ in false },
            ensureDirectory: { _ in throw DirError() }
        )
        #expect(throws: DirError.self) { try mgr.materializeHomeTree(for: mgr.accounts[0]) }
    }

    // MARK: - Forced re-auth override (#31)

    @Test("forceReauth overrides the authenticated flag")
    func forceReauthBeatsAuthenticated() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "a")
        mgr.markAuthenticated(a.id)
        #expect(mgr.needsReauth(a) == false)
        mgr.forceReauth(a.id)
        #expect(mgr.needsReauth(a) == true)
        mgr.clearForcedReauth(a.id)
        #expect(mgr.needsReauth(a) == false)
    }

    @Test("forceReauth overrides the .credentials.json short-circuit")
    func forceReauthBeatsCredentialsFile() throws {
        let mgr = makeManager(fileExists: { _ in true })   // file says "authenticated"
        let a = try mgr.createAccount(label: "a")
        #expect(mgr.needsReauth(a) == false)
        mgr.forceReauth(a.id)
        #expect(mgr.needsReauth(a) == true)
    }

    @Test("forcedReauthIds is volatile — not persisted across managers")
    func forcedVolatile() throws {
        let store = InMemoryAccountStore()
        let mgr1 = makeManager(store: store)
        let a = try mgr1.createAccount(label: "a")
        mgr1.markAuthenticated(a.id)
        mgr1.forceReauth(a.id)
        #expect(mgr1.needsReauth(a) == true)
        let mgr2 = makeManager(store: store)
        let a2 = try #require(mgr2.accounts.first { $0.label == "a" })
        #expect(mgr2.needsReauth(a2) == false)   // inherits authenticated, NOT the forced override
    }

    // bug #2 (HIGH): switching away from an account that hit a live 401 must clear
    // its forced override, or it stays pinned needs-reauth forever.
    @Test("setActive clears the prior account's forced-reauth override (bug #2)")
    func setActiveClearsPriorForced() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "a")
        let b = try mgr.createAccount(label: "b")
        mgr.markAuthenticated(a.id)        // a's static signal = authenticated
        mgr.setActive(a.id)
        mgr.forceReauth(a.id)
        #expect(mgr.needsReauth(a) == true)
        mgr.setActive(b.id)                // switch away from a
        #expect(mgr.needsReauth(a) == false)   // a's override cleared on switch-away
    }

    // bug #4 (MEDIUM): the banner Dismiss must un-force too, so banner + switcher
    // (both derived from needsReauth) stay coherent.
    @Test("acknowledgeReauth (banner dismiss) clears the forced override (bug #4)")
    func acknowledgeClearsForced() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "a")
        mgr.markAuthenticated(a.id)
        mgr.forceReauth(a.id)
        #expect(mgr.needsReauth(a) == true)
        mgr.acknowledgeReauth(a.id)
        #expect(mgr.needsReauth(a) == false)
    }

    // MARK: - Per-account config-dir isolation (#12)

    @Test("distinct accounts yield distinct configDirPaths under ~/.logos/accounts")
    func distinctConfigDirs() {
        let a = Account(id: "acc-a", label: "a")
        let b = Account(id: "acc-b", label: "b")
        #expect(a.configDirPath != b.configDirPath)
        #expect(a.configDirPath.hasSuffix("/.logos/accounts/acc-a/.claude"))
    }

    // MARK: - One-time isolated-credentials migration (#12)
    // Accounts are SEEDED via the store (simulating a pre-#12 install loaded from
    // disk) so createAccount's own ensureDirectory doesn't add noise.

    private func migrationManager(_ fs: FSDouble, _ seeded: AccountIndex) -> AccountManager {
        AccountManager(store: InMemoryAccountStore(seeded),
                       fileExists: { fs.exists($0) },
                       ensureDirectory: { try fs.ensure($0) })
    }

    @Test("migration ensures each config dir + marks accounts needs-reauth (no cred file)")
    func migrationMarksNeedsReauth() {
        let fs = FSDouble()
        let mgr = migrationManager(fs, AccountIndex(
            accounts: [Account(id: "a", label: "a"), Account(id: "b", label: "b")],
            activeAccountId: "a",
            authenticatedAccountIds: ["a", "b"]   // pre-marked; migration must clear them
        ))
        mgr.migrateToIsolatedCredentialsIfNeeded()
        #expect(mgr.needsReauth(mgr.accounts[0]) == true)
        #expect(mgr.needsReauth(mgr.accounts[1]) == true)
        #expect(Set(fs.created) == Set(mgr.accounts.map { $0.configDirPath }))
    }

    @Test("migration keeps an account authenticated when its .credentials.json exists")
    func migrationKeepsCredFileAccount() {
        let fs = FSDouble()
        let mgr = migrationManager(fs, AccountIndex(accounts: [Account(id: "a", label: "a")], activeAccountId: "a"))
        fs.present.insert("\(mgr.accounts[0].configDirPath)/.credentials.json")
        mgr.migrateToIsolatedCredentialsIfNeeded()
        #expect(mgr.needsReauth(mgr.accounts[0]) == false)
    }

    @Test("migration is idempotent — a second run is a no-op")
    func migrationIdempotent() {
        let fs = FSDouble()
        let mgr = migrationManager(fs, AccountIndex(accounts: [Account(id: "a", label: "a")], activeAccountId: "a"))
        mgr.migrateToIsolatedCredentialsIfNeeded()
        let createdAfterFirst = fs.created.count
        mgr.markAuthenticated("a")
        mgr.migrateToIsolatedCredentialsIfNeeded()   // migrated guard → no-op
        #expect(mgr.needsReauth(mgr.accounts[0]) == false)
        #expect(fs.created.count == createdAfterFirst)
    }
}

/// In-memory FS double for the migration tests (records existence + created dirs).
@MainActor
private final class FSDouble {
    var present: Set<String> = []
    var created: [String] = []
    func exists(_ path: String) -> Bool { present.contains(path) }
    func ensure(_ path: String) throws { created.append(path); present.insert(path) }
}
