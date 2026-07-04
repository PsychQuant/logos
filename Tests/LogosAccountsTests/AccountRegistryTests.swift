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
}
