import Testing
import Foundation
import LogoSwitch

@Suite("AccountManager", .serialized)
@MainActor
struct AccountManagerTests {

    private struct DirError: Error {}

    /// No real FS: `ensureDirectory` no-ops. A shared `InMemoryAccountStore` stands
    /// in for persistence across manager instances.
    private func makeManager(
        store: AccountStore = InMemoryAccountStore(),
        ensureDirectory: @escaping (String) throws -> Void = { _ in }
    ) -> AccountManager {
        AccountManager(store: store, ensureDirectory: ensureDirectory)
    }

    @Test("starts empty")
    func startsEmpty() {
        let mgr = makeManager()
        #expect(mgr.accounts.isEmpty)
        #expect(mgr.active == nil)
    }

    @Test("createAccount adds a labeled empty account; not needing login by default")
    func createAccount() throws {
        let mgr = makeManager()
        let acc = try mgr.createAccount(label: "personal")
        #expect(mgr.accounts.count == 1)
        #expect(mgr.accounts[0].label == "personal")
        #expect(mgr.needsReauth(acc) == false)   // no live 401 yet → no nudge
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
        #expect(throws: Account.ValidationError.duplicateLabel) { try mgr.createAccount(label: "x") }
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

    @Test("accounts + active persist across a fresh manager on the same store")
    func activePersists() throws {
        let store = InMemoryAccountStore()
        let mgr1 = makeManager(store: store)
        try mgr1.createAccount(label: "a")
        let b = try mgr1.createAccount(label: "b")
        mgr1.setActive(b.id)
        let mgr2 = makeManager(store: store)
        #expect(mgr2.accounts.count == 2)
        #expect(mgr2.activeAccountId == b.id)
    }

    @Test("materializeHomeTree routes through the injected ensureDirectory (no throw)")
    func materializeHomeTree() throws {
        let mgr = makeManager()
        let acc = try mgr.createAccount(label: "x")
        try mgr.materializeHomeTree(for: acc)
    }

    // bug #6: a config-dir creation failure must surface (so the spawn can be gated).
    @Test("materializeHomeTree throws when the directory cannot be created (bug #6)")
    func materializeThrowsOnDirFailure() {
        let seeded = AccountIndex(accounts: [Account(id: "a", label: "a")], activeAccountId: "a")
        let mgr = AccountManager(store: InMemoryAccountStore(seeded), ensureDirectory: { _ in throw DirError() })
        #expect(throws: DirError.self) { try mgr.materializeHomeTree(for: mgr.accounts[0]) }
    }

    @Test("distinct accounts yield distinct configDirPaths under ~/.logos/accounts")
    func distinctConfigDirs() {
        let a = Account(id: "acc-a", label: "a")
        let b = Account(id: "acc-b", label: "b")
        #expect(a.configDirPath != b.configDirPath)
        #expect(a.configDirPath.hasSuffix("/.logos/accounts/acc-a/.claude"))
    }

    // MARK: - Live-401 re-auth nudge (#31) — the ONLY auth signal Logos reads

    @Test("needsReauth tracks the live-401 override only")
    func needsReauthTracksForcedOnly() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "a")
        #expect(mgr.needsReauth(a) == false)
        mgr.forceReauth(a.id)
        #expect(mgr.needsReauth(a) == true)
        mgr.clearForcedReauth(a.id)
        #expect(mgr.needsReauth(a) == false)
    }

    @Test("forceReauth is guarded — a non-account id does not affect real accounts (bug #7)")
    func forceReauthGuarded() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "a")
        mgr.forceReauth("ghost")          // not an account → ignored, no throw
        #expect(mgr.needsReauth(a) == false)
        mgr.forceReauth(a.id)
        #expect(mgr.needsReauth(a) == true)
    }

    @Test("the live-401 override is volatile — not persisted across managers")
    func forcedVolatile() throws {
        let store = InMemoryAccountStore()
        let mgr1 = makeManager(store: store)
        let a = try mgr1.createAccount(label: "a")
        mgr1.forceReauth(a.id)
        #expect(mgr1.needsReauth(a) == true)
        let mgr2 = makeManager(store: store)
        let a2 = try #require(mgr2.accounts.first { $0.label == "a" })
        #expect(mgr2.needsReauth(a2) == false)   // session-volatile
    }

    // bug #2: switching away from an account that hit a 401 clears its nudge.
    @Test("setActive clears the prior account's live-401 override (bug #2)")
    func setActiveClearsPriorForced() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "a")
        let b = try mgr.createAccount(label: "b")
        mgr.setActive(a.id)
        mgr.forceReauth(a.id)
        #expect(mgr.needsReauth(a) == true)
        mgr.setActive(b.id)
        #expect(mgr.needsReauth(a) == false)   // cleared on switch-away
    }

    // bug #4: banner Dismiss un-forces so banner + switcher stay coherent.
    @Test("acknowledgeReauth (banner dismiss) clears the override (bug #4)")
    func acknowledgeClearsForced() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "a")
        mgr.forceReauth(a.id)
        #expect(mgr.needsReauth(a) == true)
        mgr.acknowledgeReauth(a.id)
        #expect(mgr.needsReauth(a) == false)
    }
}
