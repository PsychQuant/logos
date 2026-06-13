import Testing
import Foundation
import LogoSwitch
@testable import Logos

@Suite("AccountManager", .serialized)
@MainActor
final class AccountManagerTests {

    // #16: a class suite so `deinit` can release the isolated UserDefaults
    // suites built during each test (no orphan plists in ~/Library/Preferences).
    private let tracker = IsolatedDefaultsTracker()
    deinit { tracker.teardown() }

    @Test("starts empty")
    func startsEmpty() {
        let mgr = makeManager()
        #expect(mgr.accounts.isEmpty)
        #expect(mgr.active == nil)
    }

    @Test("add account stores label + writes creds")
    func addAccount() throws {
        let store = InMemoryCredentialStore()
        let mgr = makeManager(store: store)
        try mgr.add(label: "personal", credentials: Data("{}".utf8))
        #expect(mgr.accounts.count == 1)
        #expect(mgr.accounts[0].label == "personal")
        let firstId = mgr.accounts[0].id
        let blob = try store.load(accountId: firstId)
        #expect(blob == Data("{}".utf8))
    }

    @Test("first added becomes active by default")
    func firstActive() throws {
        let mgr = makeManager()
        try mgr.add(label: "p", credentials: Data())
        #expect(mgr.active?.label == "p")
    }

    @Test("switch active changes selection")
    func switchActive() throws {
        let mgr = makeManager()
        try mgr.add(label: "a", credentials: Data())
        try mgr.add(label: "b", credentials: Data())
        let bAccount = mgr.accounts.first(where: { $0.label == "b" })!
        mgr.setActive(bAccount.id)
        #expect(mgr.active?.label == "b")
    }

    @Test("duplicate label rejected")
    func duplicateLabel() throws {
        let mgr = makeManager()
        try mgr.add(label: "x", credentials: Data())
        #expect(throws: Account.ValidationError.duplicateLabel) {
            try mgr.add(label: "x", credentials: Data())
        }
    }

    @Test("remove account also removes creds + reassigns active")
    func removeAccount() throws {
        let store = InMemoryCredentialStore()
        let mgr = makeManager(store: store)
        try mgr.add(label: "a", credentials: Data())
        try mgr.add(label: "b", credentials: Data())
        let firstId = mgr.accounts[0].id
        try mgr.remove(accountId: firstId)
        #expect(mgr.accounts.count == 1)
        #expect(mgr.active?.label == "b")
        #expect(throws: AccountCredentialStoreError.notFound) {
            _ = try store.load(accountId: firstId)
        }
    }

    @Test("active persists across new manager init with same defaults")
    func activePersists() throws {
        let defaults = makeTransientDefaults()
        let mgr1 = AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: InMemorySystemKeychainBridge(),
            defaults: defaults
        )
        try mgr1.add(label: "a", credentials: Data())
        try mgr1.add(label: "b", credentials: Data())
        let bId = mgr1.accounts[1].id
        mgr1.setActive(bId)

        let mgr2 = AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: InMemorySystemKeychainBridge(),
            defaults: defaults
        )
        #expect(mgr2.activeAccountId == bId)
    }

    @Test("materializeHomeTree creates ~/.logos/accounts/<id>/.claude/")
    func materializeHomeTreeCreates() throws {
        let mgr = makeManager()
        try mgr.add(label: "tmpacct", credentials: Data("{\"k\":\"v\"}".utf8))
        let account = mgr.accounts[0]
        try mgr.materializeHomeTree(for: account)
        let claudeDirPath = "\(account.homeDirectoryPath)/.claude"
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: claudeDirPath, isDirectory: &isDir))
        #expect(isDir.boolValue == true)
        try? FileManager.default.removeItem(atPath: account.homeDirectoryPath)
    }

    // MARK: - E.2 new behaviors

    @Test("addByCapturingCurrent reads system bridge and saves account")
    func captureCurrent() throws {
        let bridge = InMemorySystemKeychainBridge(initial: Data("{\"capture\":\"ok\"}".utf8))
        let store = InMemoryCredentialStore()
        let mgr = AccountManager(
            store: store,
            systemBridge: bridge,
            defaults: makeTransientDefaults()
        )
        try mgr.addByCapturingCurrent(label: "default")
        #expect(mgr.accounts.count == 1)
        let id = mgr.accounts[0].id
        let stored = try store.load(accountId: id)
        #expect(stored == Data("{\"capture\":\"ok\"}".utf8))
    }

    @Test("addByCapturingCurrent throws when system bridge empty")
    func captureCurrentEmpty() {
        let bridge = InMemorySystemKeychainBridge()  // nil
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: bridge,
            defaults: makeTransientDefaults()
        )
        #expect(throws: AccountManager.AddByCaptureError.noSystemCredentials) {
            try mgr.addByCapturingCurrent(label: "x")
        }
    }

    // NOTE: the former `setActiveSwapsSystem` / `setActiveCapturesPrevious` tests
    // were removed with the swap behavior they asserted (PsychQuant/logos#12).
    // The no-write guarantee is now covered in AccountCredentialIsolationTests
    // ("setActive performs zero system-Keychain interaction").

    // MARK: - Forced re-auth override (#31) — propagate a live 401 onto needsReauth

    @Test("forceReauth overrides the authenticated flag")
    func forceReauthBeatsAuthenticatedFlag() throws {
        let mgr = makeManager()
        try mgr.add(label: "a", credentials: Data("{}".utf8))
        let acc = mgr.accounts[0]
        mgr.markAuthenticated(acc.id)
        #expect(mgr.needsReauth(acc) == false)   // authenticated → not needs-reauth
        mgr.forceReauth(acc.id)
        #expect(mgr.needsReauth(acc) == true)    // live-401 override wins
        mgr.clearForcedReauth(acc.id)
        #expect(mgr.needsReauth(acc) == false)   // cleared → back to authenticated
    }

    @Test("forceReauth overrides the .credentials.json file short-circuit (today-incoherence case)")
    func forceReauthBeatsCredentialsFile() throws {
        // Inject fileExists==true so the `.credentials.json` branch would say
        // "authenticated" — the exact stale-file case #30 verify (DA) flagged.
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: InMemorySystemKeychainBridge(),
            defaults: makeTransientDefaults(),
            fileExists: { _ in true }
        )
        try mgr.add(label: "a", credentials: Data("{}".utf8))
        let acc = mgr.accounts[0]
        #expect(mgr.needsReauth(acc) == false)   // file short-circuit
        mgr.forceReauth(acc.id)
        #expect(mgr.needsReauth(acc) == true)    // override beats the file short-circuit
    }

    @Test("forcedReauthIds is volatile — not persisted across manager instances")
    func forcedReauthIsVolatile() throws {
        let defaults = makeTransientDefaults()
        let mgr1 = AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: InMemorySystemKeychainBridge(),
            defaults: defaults
        )
        try mgr1.add(label: "a", credentials: Data("{}".utf8))
        mgr1.markAuthenticated(mgr1.accounts[0].id)
        mgr1.forceReauth(mgr1.accounts[0].id)
        #expect(mgr1.needsReauth(mgr1.accounts[0]) == true)

        // A fresh manager on the same defaults inherits the persisted authenticated
        // flag but NOT the session-volatile forced override.
        let mgr2 = AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: InMemorySystemKeychainBridge(),
            defaults: defaults
        )
        let acc2 = try #require(mgr2.accounts.first { $0.label == "a" })
        #expect(mgr2.needsReauth(acc2) == false)
    }

    // MARK: - Helpers

    private func makeManager(
        store: AccountCredentialStore = InMemoryCredentialStore()
    ) -> AccountManager {
        AccountManager(
            store: store,
            systemBridge: InMemorySystemKeychainBridge(),
            defaults: makeTransientDefaults()
        )
    }

    private func makeTransientDefaults() -> UserDefaults {
        tracker.make(prefix: "LogosE2")
    }
}
