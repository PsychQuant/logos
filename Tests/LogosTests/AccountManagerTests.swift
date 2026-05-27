import Testing
import Foundation
@testable import Logos

@Suite("AccountManager", .serialized)
@MainActor
struct AccountManagerTests {

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
        mgr.setActive(bAccount.id, captureCurrent: false)
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
        mgr1.setActive(bId, captureCurrent: false)

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

    @Test("setActive writes target account's creds to system bridge")
    func setActiveSwapsSystem() throws {
        let bridge = InMemorySystemKeychainBridge()
        let store = InMemoryCredentialStore()
        let mgr = AccountManager(
            store: store,
            systemBridge: bridge,
            defaults: makeTransientDefaults()
        )
        try mgr.add(label: "work", credentials: Data("{\"work\":1}".utf8))
        try mgr.add(label: "personal", credentials: Data("{\"personal\":1}".utf8))
        // first add ("work") set active but didn't swap (no prior creds to compare).
        // Now switch to personal — should write personal's creds to bridge.
        let personalId = mgr.accounts[1].id
        mgr.setActive(personalId, captureCurrent: false)
        let written = try bridge.read()
        #expect(written == Data("{\"personal\":1}".utf8))
    }

    @Test("setActive captures current system entry into previous active")
    func setActiveCapturesPrevious() throws {
        let bridge = InMemorySystemKeychainBridge()
        let store = InMemoryCredentialStore()
        let mgr = AccountManager(
            store: store,
            systemBridge: bridge,
            defaults: makeTransientDefaults()
        )
        try mgr.add(label: "work", credentials: Data("{\"work_old\":1}".utf8))
        try mgr.add(label: "personal", credentials: Data("{\"personal\":1}".utf8))

        // Simulate claude refreshing tokens for work: bridge now has updated work creds.
        try bridge.write(Data("{\"work_refreshed\":1}".utf8))

        // Switch to personal with captureCurrent=true (default).
        let personalId = mgr.accounts[1].id
        mgr.setActive(personalId)

        // Previous active was "work" (first added). Its stored creds should now be the refreshed value.
        let workId = mgr.accounts[0].id
        let storedWork = try store.load(accountId: workId)
        #expect(storedWork == Data("{\"work_refreshed\":1}".utf8))
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
        UserDefaults(suiteName: "LogosE2_\(UUID().uuidString)")!
    }
}
