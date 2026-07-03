import Testing
import Foundation
import LogoSwitch

/// Active-selection persistence (merge-multistats-into-logos). The account
/// LIST moved to the shared AccountRegistry index file; this store keeps ONLY
/// the app-local active id — and must never touch the legacy `logos.accounts`
/// blob, which stays in place as the registry migration's read-fallback.
@Suite("ActiveAccountStore", .serialized)
@MainActor
struct AccountStoreTests {

    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "active-store-tests-\(UUID().uuidString)"))
    }

    @Test("in-memory store round-trips the active id")
    func inMemoryRoundTrip() {
        let store = InMemoryActiveAccountStore()
        #expect(store.loadActiveAccountId() == nil)
        store.saveActiveAccountId("acc-1")
        #expect(store.loadActiveAccountId() == "acc-1")
        store.saveActiveAccountId(nil)
        #expect(store.loadActiveAccountId() == nil)
    }

    @Test("UserDefaults store round-trips the active id")
    func defaultsRoundTrip() throws {
        let d = try freshDefaults()
        let store = UserDefaultsActiveAccountStore(defaults: d)
        store.saveActiveAccountId("acc-9")
        #expect(UserDefaultsActiveAccountStore(defaults: d).loadActiveAccountId() == "acc-9")
        store.saveActiveAccountId(nil)
        #expect(UserDefaultsActiveAccountStore(defaults: d).loadActiveAccountId() == nil)
    }

    @Test("pre-registry activeId key survives the upgrade (same key)")
    func upgradeCompatibleKey() throws {
        let d = try freshDefaults()
        // What the pre-registry UserDefaultsAccountStore wrote.
        d.set("acc-legacy", forKey: "logos.accounts.activeId")
        #expect(UserDefaultsActiveAccountStore(defaults: d).loadActiveAccountId() == "acc-legacy")
    }

    @Test("saving the selection never touches the legacy logos.accounts blob")
    func legacyBlobUntouched() throws {
        let d = try freshDefaults()
        let legacyBlob = Data("legacy-account-list".utf8)
        d.set(legacyBlob, forKey: "logos.accounts")

        let store = UserDefaultsActiveAccountStore(defaults: d)
        store.saveActiveAccountId("acc-1")
        store.saveActiveAccountId(nil)

        #expect(d.data(forKey: "logos.accounts") == legacyBlob)
    }
}
