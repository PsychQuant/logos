import Testing
import Foundation
import LogoSwitch
import LogosAccounts

@Suite("AccountManager", .serialized)
@MainActor
struct AccountManagerTests {

    private struct DirError: Error {}

    private func tempIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("account-manager-tests-\(UUID().uuidString)")
            .appendingPathComponent("index.json")
    }

    /// No real FS beyond a per-test temp index file: `ensureDirectory` no-ops.
    /// Re-using the same `indexFileURL` + store across two managers stands in
    /// for persistence across app launches.
    private func makeManager(
        indexFileURL: URL? = nil,
        store: ActiveAccountStore = InMemoryActiveAccountStore(),
        ensureDirectory: @escaping (String) throws -> Void = { _ in }
    ) -> AccountManager {
        AccountManager(
            registry: AccountRegistry(indexFileURL: indexFileURL ?? tempIndexURL()),
            store: store,
            ensureDirectory: ensureDirectory)
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

    @Test("accounts + active persist across a fresh manager on the same registry + store")
    func activePersists() throws {
        let url = tempIndexURL()
        let store = InMemoryActiveAccountStore()
        let mgr1 = makeManager(indexFileURL: url, store: store)
        try mgr1.createAccount(label: "a")
        let b = try mgr1.createAccount(label: "b")
        mgr1.setActive(b.id)
        let mgr2 = makeManager(indexFileURL: url, store: store)
        #expect(mgr2.accounts.count == 2)
        #expect(mgr2.activeAccountId == b.id)
    }

    // merge-multistats-into-logos: "Active selection stays out of the shared
    // registry" — switching writes the app-local store, never the index file.
    @Test("setActive leaves the shared index file unmodified")
    func setActiveDoesNotWriteIndex() throws {
        let url = tempIndexURL()
        let store = InMemoryActiveAccountStore()
        let mgr = makeManager(indexFileURL: url, store: store)
        try mgr.createAccount(label: "a")
        let b = try mgr.createAccount(label: "b")
        let before = try Data(contentsOf: url)
        mgr.setActive(b.id)
        #expect(try Data(contentsOf: url) == before)
        #expect(store.loadActiveAccountId() == b.id)
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
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try? registry.add(Account(id: "a", label: "a"))
        let mgr = AccountManager(
            registry: registry,
            store: InMemoryActiveAccountStore("a"),
            ensureDirectory: { _ in throw DirError() })
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
        let url = tempIndexURL()
        let store = InMemoryActiveAccountStore()
        let mgr1 = makeManager(indexFileURL: url, store: store)
        let a = try mgr1.createAccount(label: "a")
        mgr1.forceReauth(a.id)
        #expect(mgr1.needsReauth(a) == true)
        let mgr2 = makeManager(indexFileURL: url, store: store)
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

    // MARK: - Rename (#36)

    @Test("rename changes the label, preserving id + createdAt")
    func renamePreservesIdentity() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "work")
        try mgr.rename(accountId: a.id, to: "office")
        let renamed = try #require(mgr.accounts.first { $0.id == a.id })
        #expect(renamed.label == "office")
        #expect(renamed.id == a.id)
        #expect(renamed.createdAt == a.createdAt)
    }

    @Test("rename rejects a duplicate of ANOTHER account's label")
    func renameRejectsDuplicate() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "work")
        try mgr.createAccount(label: "home")
        #expect(throws: Account.ValidationError.duplicateLabel) {
            try mgr.rename(accountId: a.id, to: "home")
        }
        #expect(mgr.accounts.first { $0.id == a.id }?.label == "work")   // unchanged
    }

    @Test("rename to the account's OWN label is allowed (not a false duplicate)")
    func renameToOwnLabelAllowed() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "work")
        try mgr.rename(accountId: a.id, to: "work")   // no throw
        #expect(mgr.accounts.first { $0.id == a.id }?.label == "work")
    }

    @Test("rename rejects empty / too-long labels")
    func renameRejectsInvalid() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "work")
        #expect(throws: Account.ValidationError.emptyLabel) {
            try mgr.rename(accountId: a.id, to: "   ")
        }
        #expect(throws: Account.ValidationError.labelTooLong) {
            try mgr.rename(accountId: a.id, to: String(repeating: "x", count: 31))
        }
    }

    @Test("rename persists across a fresh manager on the same registry")
    func renamePersists() throws {
        let url = tempIndexURL()
        let mgr1 = makeManager(indexFileURL: url)
        let a = try mgr1.createAccount(label: "work")
        try mgr1.rename(accountId: a.id, to: "office")
        let mgr2 = makeManager(indexFileURL: url)
        #expect(mgr2.accounts.first { $0.id == a.id }?.label == "office")
    }

    @Test("rename of a non-existent id is a no-op")
    func renameNonexistentNoOp() throws {
        let mgr = makeManager()
        let a = try mgr.createAccount(label: "work")
        try mgr.rename(accountId: "ghost", to: "whatever")   // no throw, no change
        #expect(mgr.accounts.count == 1)
        #expect(mgr.accounts.first { $0.id == a.id }?.label == "work")
    }

    // MARK: - System-default (main) account (#54)

    // The system-default account reuses the real ~/.claude — Logos must NEVER
    // mkdir over it. materializeHomeTree must no-op for it (an injected throwing
    // ensureDirectory proves the creation path is not taken).
    @Test("materializeHomeTree no-ops for a system-default account (never mkdir over ~/.claude)")
    func materializeHomeTreeNoOpForSystemDefault() throws {
        let mgr = makeManager(ensureDirectory: { _ in throw DirError() })
        let systemAccount = Account(id: "main", label: "Main", isSystemDefault: true)
        try mgr.materializeHomeTree(for: systemAccount)   // must NOT throw
    }

    // Isolated accounts still route through ensureDirectory (regression guard).
    @Test("materializeHomeTree still creates the dir for an isolated account")
    func materializeHomeTreeCreatesForIsolated() {
        let mgr = makeManager(ensureDirectory: { _ in throw DirError() })
        let isolated = Account(id: "work", label: "work")   // isSystemDefault false
        #expect(throws: DirError.self) { try mgr.materializeHomeTree(for: isolated) }
    }

    @Test("addSystemDefaultAccount registers exactly one system-default account, idempotently")
    func addSystemDefaultAccountIdempotent() {
        let mgr = makeManager()
        mgr.addSystemDefaultAccount()
        #expect(mgr.accounts.filter(\.isSystemDefault).count == 1)
        mgr.addSystemDefaultAccount()   // dedup-guarded → still exactly one
        #expect(mgr.accounts.filter(\.isSystemDefault).count == 1)
    }

    // #54 verify B1: rename must not silently de-system the main account. The
    // registry rebuilds the Account on rename — it MUST thread isSystemDefault,
    // or renaming "Main" would flip spawnConfigDir nil→dir and lose the ~/.claude
    // login. (logic lens + DA, verify comment.)
    @Test("rename preserves isSystemDefault (#54 verify B1)")
    func renamePreservesSystemDefault() throws {
        let mgr = makeManager()
        _ = mgr.addSystemDefaultAccount()
        let main = try #require(mgr.accounts.first { $0.isSystemDefault })
        try mgr.rename(accountId: main.id, to: "Home")
        let renamed = try #require(mgr.accounts.first { $0.id == main.id })
        #expect(renamed.isSystemDefault == true)   // survives the rename
        #expect(renamed.label == "Home")
    }

    // #56 gap 3: addSystemDefaultAccount returns a result so the switcher can
    // distinguish added from the expected idempotent already-exists.
    @Test("addSystemDefaultAccount returns .added then .alreadyExists, with the fixed id (#56)")
    func addSystemDefaultReturnsResult() throws {
        let mgr = makeManager()
        let r1 = mgr.addSystemDefaultAccount()
        guard case .added(let acc) = r1 else { Issue.record("expected .added, got \(r1)"); return }
        #expect(acc.id == Account.systemDefaultID)
        let r2 = mgr.addSystemDefaultAccount()
        guard case .alreadyExists = r2 else { Issue.record("expected .alreadyExists, got \(r2)"); return }
        #expect(mgr.accounts.filter(\.isSystemDefault).count == 1)
    }

    // #56 gap 1: a pre-existing isolated "Main" no longer blocks the system account.
    @Test("an isolated Main does not block addSystemDefaultAccount (#56)")
    func isolatedMainDoesNotBlockSystemDefault() throws {
        let mgr = makeManager()
        try mgr.createAccount(label: "Main")   // isolated "Main"
        let r = mgr.addSystemDefaultAccount()
        guard case .added = r else { Issue.record("expected .added despite isolated Main, got \(r)"); return }
        #expect(mgr.accounts.filter(\.isSystemDefault).count == 1)
        #expect(mgr.accounts.count == 2)
    }

    // #56 verify B1 (ensemble #3): the REVERSE order must also work — a
    // system-default "Main" present first must not block createAccount("Main").
    @Test("createAccount coexists with a same-label system-default (#56 verify B1)")
    func createAccountCoexistsWithSystemDefault() throws {
        let mgr = makeManager()
        _ = mgr.addSystemDefaultAccount()               // system-default "Main" first
        let acc = try mgr.createAccount(label: "Main")  // isolated "Main" — must NOT throw
        #expect(acc.label == "Main")
        #expect(mgr.accounts.count == 2)
    }

    // #56 verify B3 (ensemble #2/#5/#13/#15): when the system-default's id migrates
    // (UUID → fixed), the stored active id dangles; init self-heal must land on the
    // system-default (not accounts.first), even when it isn't first.
    @Test("active resolves to the system-default after its id migrates (#56 verify B3)")
    func activeResolvesToSystemDefaultAfterMigration() throws {
        let url = tempIndexURL()
        let seed = AccountRegistry(indexFileURL: url)
        try seed.add(Account(label: "Work"))                                        // isolated, FIRST
        try seed.add(Account(id: "legacy-uuid", label: "Main", isSystemDefault: true))  // system-default, UUID id
        let store = InMemoryActiveAccountStore()
        store.saveActiveAccountId("legacy-uuid")                                     // active = the pre-migration UUID
        // manager: its registry init migrates legacy-uuid → systemDefaultID; active dangles → self-heal
        let mgr = makeManager(indexFileURL: url, store: store)
        #expect(mgr.active?.isSystemDefault == true)
        #expect(mgr.active?.id == Account.systemDefaultID)
    }

    // #56 verify B4 (ensemble #4): a persist failure must return .failed, NOT .added,
    // and must not write a dangling active id.
    @Test("addSystemDefaultAccount returns .failed on persist failure without setting active (#56 verify B4)")
    func addSystemDefaultFailedPath() throws {
        // Make the index path unwritable: its parent is a regular FILE, so save's
        // createDirectory(parent) throws.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("b4-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        let url = blocker.appendingPathComponent("index.json")   // parent (blocker) is a file
        let store = InMemoryActiveAccountStore()
        let mgr = makeManager(indexFileURL: url, store: store)
        let r = mgr.addSystemDefaultAccount()
        guard case .failed = r else { Issue.record("expected .failed on persist failure, got \(r)"); return }
        #expect(store.loadActiveAccountId() == nil)   // no dangling active persisted
        #expect(mgr.accounts.isEmpty)                 // #56 verify C2: no phantom account left in memory
    }

    // #56 verify C1 (round-2 #4): a FRESH launch (no stored active id) keeps the
    // historical accounts.first seed — only a DANGLING id heals to the system-default.
    @Test("fresh launch (no stored active) seeds accounts.first, not the system-default (#56 verify C1)")
    func freshActiveKeepsAccountsFirst() throws {
        let url = tempIndexURL()
        let seed = AccountRegistry(indexFileURL: url)
        try seed.add(Account(label: "Work"))                                            // isolated, FIRST
        try seed.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))
        let mgr = makeManager(indexFileURL: url, store: InMemoryActiveAccountStore())    // fresh store: no active
        #expect(mgr.active?.label == "Work")            // historical accounts.first, not the system-default
        #expect(mgr.active?.isSystemDefault == false)
    }

    // #57 F4 (round-2 #6): when the registry's normalize repair did NOT persist (disk
    // write failed), a healed active id must NOT be written to the store — else the store
    // would point at an id the on-disk index doesn't hold.
    @Test("healed active is not persisted when normalize's repair didn't persist (#57 F4)")
    func healedActiveNotPersistedOnNormalizeFail() throws {
        let url = tempIndexURL()
        // corrupt index: a legacy-uuid system-default normalize will want to migrate.
        let iso = ISO8601DateFormatter()
        let json = "{\"version\":1,\"accounts\":[{\"id\":\"legacy-uuid\",\"label\":\"Main\",\"createdAt\":\"\(iso.string(from: Date(timeIntervalSince1970: 1_000)))\",\"isSystemDefault\":true}]}"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let store = InMemoryActiveAccountStore()
        store.saveActiveAccountId("legacy-uuid")               // active = the pre-migration id
        // read-only dir → normalize's migrate save fails → normalizeDidPersist == false
        let parent = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let mgr = makeManager(indexFileURL: url, store: store)
        #expect(store.loadActiveAccountId() == "legacy-uuid")  // F4: NOT overwritten (repair didn't persist)
        #expect(mgr.active?.isSystemDefault == true)           // but in-memory still heals correctly
    }
}
