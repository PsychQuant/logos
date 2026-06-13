import Testing
import Foundation
import LogoSwitch

@Suite("AccountStore", .serialized)
@MainActor
struct AccountStoreTests {

    // MARK: InMemoryAccountStore

    @Test("in-memory store round-trips an index")
    func inMemoryRoundTrip() {
        let store = InMemoryAccountStore()
        let index = AccountIndex(
            accounts: [Account(id: "a", label: "work")],
            activeAccountId: "a",
            authenticatedAccountIds: ["a"],
            migrated: true
        )
        store.save(index)
        #expect(store.load() == index)
    }

    // MARK: UserDefaultsAccountStore (volatile suite)

    private func volatileDefaults() -> (UserDefaults, String) {
        let name = "logoswitch.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (d, name)
    }

    @Test("UserDefaults store save → load round-trips")
    func userDefaultsRoundTrip() {
        let (d, name) = volatileDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let store = UserDefaultsAccountStore(defaults: d)
        let index = AccountIndex(
            accounts: [Account(id: "a", label: "work"), Account(id: "b", label: "home")],
            activeAccountId: "b",
            authenticatedAccountIds: ["a"],
            migrated: true
        )
        store.save(index)
        #expect(UserDefaultsAccountStore(defaults: d).load() == index)
    }

    @Test("empty defaults load to .empty (no crash, no phantom accounts)")
    func emptyLoadsEmpty() {
        let (d, name) = volatileDefaults()
        defer { d.removePersistentDomain(forName: name) }
        #expect(UserDefaultsAccountStore(defaults: d).load() == .empty)
    }

    // THE data-loss regression (#34 / Swift6 + bug-efficacy must-fix): a pre-#34
    // install persisted FOUR separate `logos.accounts*` keys, NOT one AccountIndex
    // blob. load() must recover that legacy layout, not wipe it.
    @Test("load recovers the pre-#34 legacy four-key layout (no data loss)")
    func recoversLegacyFourKeyLayout() throws {
        let (d, name) = volatileDefaults()
        defer { d.removePersistentDomain(forName: name) }

        // Seed exactly as the pre-#34 AccountManager.persistToDefaults wrote them.
        let legacyAccounts = [Account(id: "acc-1", label: "work"), Account(id: "acc-2", label: "home")]
        d.set(try JSONEncoder().encode(legacyAccounts), forKey: "logos.accounts")
        d.set("acc-2", forKey: "logos.accounts.activeId")
        d.set(["acc-1"], forKey: "logos.accounts.authenticatedIds")
        d.set(true, forKey: "logos.accounts.migratedIsolatedCredentials")

        let index = UserDefaultsAccountStore(defaults: d).load()
        #expect(index.accounts == legacyAccounts)
        #expect(index.activeAccountId == "acc-2")
        #expect(index.authenticatedAccountIds == ["acc-1"])
        #expect(index.migrated == true)
    }
}
