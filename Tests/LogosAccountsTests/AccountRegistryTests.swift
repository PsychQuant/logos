import Foundation
import Testing
@testable import LogosAccounts

/// Registry persistence + mutation contract (merge-multistats-into-logos,
/// spec account-registry). Every test runs against a temp index file — the
/// shared file IS the behavior under test, so no in-memory fake here.
@Suite("AccountRegistry")
struct AccountRegistryTests {

    private func tempIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-tests-\(UUID().uuidString)")
            .appendingPathComponent("index.json")
    }

    // MARK: - "Account list persists in a shared file-based index"

    @Test("create/rename/remove round-trips through the index file")
    @MainActor func roundTrip() throws {
        let url = tempIndexURL()

        let registry = AccountRegistry(indexFileURL: url)
        let work = try registry.create(label: "work")
        let personal = try registry.create(label: "personal")
        try registry.rename(accountId: personal.id, to: "Personal 2")
        registry.remove(accountId: work.id)

        // A second instance on the same file = "the other executable".
        let reloaded = AccountRegistry(indexFileURL: url)
        #expect(reloaded.accounts.count == 1)
        let survivor = try #require(reloaded.accounts.first)
        #expect(survivor.id == personal.id)
        #expect(survivor.label == "Personal 2")
        #expect(abs(survivor.createdAt.timeIntervalSince(personal.createdAt)) < 1)
    }

    @Test("index file carries version 1 and only the account list")
    @MainActor func fileShape() throws {
        let url = tempIndexURL()
        let registry = AccountRegistry(indexFileURL: url)
        try registry.create(label: "work")
        try registry.create(label: "personal")

        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        // Active selection (or anything else) must never leak into the shared
        // index — "Active selection stays out of the shared registry".
        #expect(Set(object.keys) == ["version", "accounts"])

        let accounts = try #require(object["accounts"] as? [[String: Any]])
        #expect(accounts.count == 2)
        for entry in accounts {
            #expect(entry["id"] is String)
            #expect(entry["label"] is String)
            // ISO-8601 string, not a numeric epoch.
            let createdAt = try #require(entry["createdAt"] as? String)
            #expect(createdAt.contains("T"))
        }
    }

    @Test("save creates the parent directory when missing")
    @MainActor func createsParentDirectory() throws {
        let url = tempIndexURL()   // parent dir does not exist yet
        let registry = AccountRegistry(indexFileURL: url)
        try registry.create(label: "work")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("absent index file loads as empty")
    @MainActor func absentFile() {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        #expect(registry.accounts.isEmpty)
    }

    // MARK: - "Registry mutations validate labels"

    @Test("empty label is rejected")
    @MainActor func emptyLabel() {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        #expect(throws: Account.ValidationError.emptyLabel) {
            try registry.create(label: "   ")
        }
    }

    @Test("31-character label is rejected")
    @MainActor func labelTooLong() {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        #expect(throws: Account.ValidationError.labelTooLong) {
            try registry.create(label: String(repeating: "x", count: 31))
        }
    }

    @Test("duplicate label on create is rejected")
    @MainActor func duplicateCreate() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.create(label: "work")
        #expect(throws: Account.ValidationError.duplicateLabel) {
            try registry.create(label: "work")
        }
    }

    @Test("renaming an account to its own label succeeds")
    @MainActor func ownLabelRename() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        let account = try registry.create(label: "work")
        try registry.rename(accountId: account.id, to: "work")
        #expect(registry.accounts.first?.label == "work")
    }

    @Test("renaming to another account's label is rejected")
    @MainActor func duplicateRename() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.create(label: "work")
        let personal = try registry.create(label: "personal")
        #expect(throws: Account.ValidationError.duplicateLabel) {
            try registry.rename(accountId: personal.id, to: "work")
        }
    }

    @Test("rename preserves id and createdAt")
    @MainActor func renamePreservesIdentity() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        let account = try registry.create(label: "work")
        try registry.rename(accountId: account.id, to: "Work 2")
        let renamed = try #require(registry.accounts.first)
        #expect(renamed.id == account.id)
        #expect(renamed.createdAt == account.createdAt)
        #expect(renamed.label == "Work 2")
    }

    // MARK: - System-default hardening (#56)

    // #56 gap 1: label uniqueness applies to isolated accounts only — a
    // system-default "Main" coexists with an isolated "Main" (identity is the id).
    @Test("a system-default coexists with an isolated account of the same label (#56)")
    @MainActor func systemDefaultCoexistsWithIsolatedSameLabel() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.add(Account(label: "Main"))                                        // isolated
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))  // system-default
        #expect(registry.accounts.count == 2)
        #expect(registry.accounts.filter(\.isSystemDefault).count == 1)
    }

    // #56 gap 2: load-time normalize enforces "at most one system-default" —
    // keep earliest createdAt, demote the rest to isolated.
    @Test("normalize demotes ≥2 persisted system-defaults to one (earliest kept) (#56)")
    @MainActor func normalizeDemotesExtraSystemDefaults() throws {
        let url = tempIndexURL()
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        let r1 = AccountRegistry(indexFileURL: url)
        try r1.add(Account(id: "sd-early", label: "Main", createdAt: earlier, isSystemDefault: true))
        try r1.add(Account(id: "sd-late", label: "Other", createdAt: later, isSystemDefault: true))
        // reload → init runs normalize
        let r2 = AccountRegistry(indexFileURL: url)
        #expect(r2.accounts.filter(\.isSystemDefault).count == 1)
        let survivor = try #require(r2.accounts.first(where: { $0.isSystemDefault }))
        #expect(survivor.createdAt == earlier)      // earliest kept
        #expect(r2.accounts.count == 2)             // the other is demoted, not deleted
    }

    // #56 gap 2 / decision 4: normalize migrates a legacy UUID system-default id
    // to the fixed systemDefaultID.
    @Test("normalize migrates a legacy UUID system-default id to systemDefaultID (#56)")
    @MainActor func normalizeMigratesLegacyID() throws {
        let url = tempIndexURL()
        let r1 = AccountRegistry(indexFileURL: url)
        try r1.add(Account(id: "legacy-uuid-1234", label: "Main", isSystemDefault: true))
        let r2 = AccountRegistry(indexFileURL: url)
        #expect(r2.accounts.first(where: { $0.isSystemDefault })?.id == Account.systemDefaultID)
    }

    // #56: a clean 0/1-system-default index must not be spuriously rewritten by normalize.
    @Test("normalize leaves a clean single system-default index byte-unchanged (#56)")
    @MainActor func normalizeLeavesCleanIndexUnchanged() throws {
        let url = tempIndexURL()
        let r1 = AccountRegistry(indexFileURL: url)
        try r1.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))
        let before = try Data(contentsOf: url)
        _ = AccountRegistry(indexFileURL: url)      // reload → normalize should be a no-op
        #expect(try Data(contentsOf: url) == before)
    }

    // #56 verify B1 (ensemble #3/#10): coexistence must be order-INdependent — a
    // pre-existing system-default "Main" must not block adding an isolated "Main".
    @Test("reverse order: system-default first, then isolated same label coexist (#56 verify B1)")
    @MainActor func systemDefaultFirstThenIsolatedSameLabel() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))  // system-default FIRST
        try registry.add(Account(label: "Main"))                                                       // isolated same label
        #expect(registry.accounts.count == 2)
        #expect(registry.accounts.filter { !$0.isSystemDefault }.count == 1)
    }

    // #56 verify B2 (ensemble #1/#11/#12/#23): normalize must not synthesize two
    // accounts sharing id "system-default" when the demoted extra already holds it.
    @Test("normalize does not create duplicate ids when a demoted extra already holds the fixed id (#56 verify B2)")
    @MainActor func normalizeNoDuplicateIDOnCollision() throws {
        let url = tempIndexURL()
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        let r1 = AccountRegistry(indexFileURL: url)
        try r1.add(Account(id: "legacy-uuid", label: "Main", createdAt: earlier, isSystemDefault: true))        // canonical (earlier) → migrates INTO the fixed id
        try r1.add(Account(id: Account.systemDefaultID, label: "Old", createdAt: later, isSystemDefault: true)) // later, already holds the fixed id → demoted
        let r2 = AccountRegistry(indexFileURL: url)   // normalize
        let ids = r2.accounts.map(\.id)
        #expect(Set(ids).count == ids.count)          // no duplicate ids
        #expect(r2.accounts.filter { $0.id == Account.systemDefaultID }.count == 1)
        #expect(r2.accounts.filter { $0.isSystemDefault }.count == 1)
    }
}
