import Testing
import Foundation
@testable import Logos

@Suite("AccountManager", .serialized)
@MainActor
struct AccountManagerTests {

    @Test("starts empty")
    func startsEmpty() {
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            defaults: makeTransientDefaults()
        )
        #expect(mgr.accounts.isEmpty)
        #expect(mgr.active == nil)
    }

    @Test("add account stores label + writes creds")
    func addAccount() throws {
        let store = InMemoryCredentialStore()
        let mgr = AccountManager(store: store, defaults: makeTransientDefaults())
        try mgr.add(label: "personal", credentials: Data("{}".utf8))
        #expect(mgr.accounts.count == 1)
        #expect(mgr.accounts[0].label == "personal")
        let firstId = mgr.accounts[0].id
        let blob = try store.load(accountId: firstId)
        #expect(blob == Data("{}".utf8))
    }

    @Test("first added becomes active by default")
    func firstActive() throws {
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            defaults: makeTransientDefaults()
        )
        try mgr.add(label: "p", credentials: Data())
        #expect(mgr.active?.label == "p")
    }

    @Test("switch active changes selection")
    func switchActive() throws {
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            defaults: makeTransientDefaults()
        )
        try mgr.add(label: "a", credentials: Data())
        try mgr.add(label: "b", credentials: Data())
        let bAccount = mgr.accounts.first(where: { $0.label == "b" })!
        mgr.setActive(bAccount.id)
        #expect(mgr.active?.label == "b")
    }

    @Test("duplicate label rejected")
    func duplicateLabel() throws {
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            defaults: makeTransientDefaults()
        )
        try mgr.add(label: "x", credentials: Data())
        #expect(throws: Account.ValidationError.duplicateLabel) {
            try mgr.add(label: "x", credentials: Data())
        }
    }

    @Test("remove account also removes creds + reassigns active")
    func removeAccount() throws {
        let store = InMemoryCredentialStore()
        let mgr = AccountManager(store: store, defaults: makeTransientDefaults())
        try mgr.add(label: "a", credentials: Data())
        try mgr.add(label: "b", credentials: Data())
        let firstId = mgr.accounts[0].id
        try mgr.remove(accountId: firstId)
        #expect(mgr.accounts.count == 1)
        #expect(mgr.active?.label == "b")
        // Credentials should be gone too
        #expect(throws: AccountCredentialStoreError.notFound) {
            _ = try store.load(accountId: firstId)
        }
    }

    @Test("active persists across new manager init with same defaults")
    func activePersists() throws {
        let defaults = makeTransientDefaults()
        let store1 = InMemoryCredentialStore()
        let mgr1 = AccountManager(store: store1, defaults: defaults)
        try mgr1.add(label: "a", credentials: Data())
        try mgr1.add(label: "b", credentials: Data())
        let bId = mgr1.accounts[1].id
        mgr1.setActive(bId)

        // New manager with same defaults should restore active selection
        let mgr2 = AccountManager(store: InMemoryCredentialStore(), defaults: defaults)
        #expect(mgr2.activeAccountId == bId)
    }

    @Test("materializeHomeTree creates ~/.logos/accounts/<id>/.claude/.credentials.json")
    func materializeHomeTreeCreates() throws {
        let store = InMemoryCredentialStore()
        let mgr = AccountManager(store: store, defaults: makeTransientDefaults())
        try mgr.add(label: "tmpacct", credentials: Data("{\"k\":\"v\"}".utf8))
        let account = mgr.accounts[0]
        try mgr.materializeHomeTree(for: account)
        let credsPath = "\(account.homeDirectoryPath)/.claude/.credentials.json"
        #expect(FileManager.default.fileExists(atPath: credsPath))
        let loaded = try Data(contentsOf: URL(fileURLWithPath: credsPath))
        #expect(loaded == Data("{\"k\":\"v\"}".utf8))
        // Cleanup
        try? FileManager.default.removeItem(atPath: account.homeDirectoryPath)
    }

    // Helper
    private func makeTransientDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LogosE_\(UUID().uuidString)")!
    }
}
