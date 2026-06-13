import Testing
import Foundation
import LogoSwitch

@Suite("AccountStore", .serialized)
@MainActor
struct AccountStoreTests {

    @Test("in-memory store round-trips an index")
    func inMemoryRoundTrip() {
        let store = InMemoryAccountStore()
        let index = AccountIndex(accounts: [Account(id: "a", label: "work")], activeAccountId: "a")
        store.save(index)
        #expect(store.load() == index)
    }

    private func volatileDefaults() -> (UserDefaults, String) {
        let name = "logoswitch.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("UserDefaults store save → load round-trips")
    func userDefaultsRoundTrip() {
        let (d, name) = volatileDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let store = UserDefaultsAccountStore(defaults: d)
        let index = AccountIndex(
            accounts: [Account(id: "a", label: "work"), Account(id: "b", label: "home")],
            activeAccountId: "b"
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

    // Existing users persisted accounts + active under these keys before #34;
    // load() must recover them. The pre-#34 auth keys (authenticatedIds /
    // migratedIsolatedCredentials) are no longer read — they must be ignored, not
    // crash (auth state is claude's job now, #34).
    @Test("load recovers persisted accounts + active and ignores stale auth keys")
    func recoversAccountsAndActive() throws {
        let (d, name) = volatileDefaults()
        defer { d.removePersistentDomain(forName: name) }
        let accounts = [Account(id: "acc-1", label: "work"), Account(id: "acc-2", label: "home")]
        d.set(try JSONEncoder().encode(accounts), forKey: "logos.accounts")
        d.set("acc-2", forKey: "logos.accounts.activeId")
        d.set(["acc-1"], forKey: "logos.accounts.authenticatedIds")            // stale, ignored
        d.set(true, forKey: "logos.accounts.migratedIsolatedCredentials")      // stale, ignored

        let index = UserDefaultsAccountStore(defaults: d).load()
        #expect(index.accounts == accounts)
        #expect(index.activeAccountId == "acc-2")
    }
}
