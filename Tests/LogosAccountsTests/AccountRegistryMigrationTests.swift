import Foundation
import Testing
@testable import LogosAccounts

/// One-time UserDefaults -> index-file migration (merge-multistats-into-logos,
/// spec account-registry: "Legacy per-app account data migrates
/// non-destructively"). The legacy store wrote `logos.accounts` via
/// JSONEncoder's DEFAULT date strategy (epoch-reference double), which is why
/// these fixtures encode the same way — the migration must decode that shape,
/// not the new ISO-8601 index shape.
@Suite("AccountRegistry migration")
struct AccountRegistryMigrationTests {

    private func tempIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-migration-\(UUID().uuidString)")
            .appendingPathComponent("index.json")
    }

    private func freshSuite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "registry-migration-\(UUID().uuidString)"))
    }

    @Test("decodable legacy data produces an identical index file, legacy untouched")
    @MainActor func migratesLegacyAccounts() throws {
        let url = tempIndexURL()
        let defaults = try freshSuite()
        let legacy = [
            Account(id: "id-work", label: "work", createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            Account(id: "id-personal", label: "personal", createdAt: Date(timeIntervalSince1970: 1_710_000_000)),
        ]
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: "logos.accounts")

        let registry = AccountRegistry(indexFileURL: url, legacyDefaults: defaults)

        #expect(registry.accounts.map(\.id) == ["id-work", "id-personal"])
        #expect(registry.accounts.map(\.label) == ["work", "personal"])
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Reload from the file alone (no legacy) — the index is now authoritative.
        let reloaded = AccountRegistry(indexFileURL: url)
        #expect(reloaded.accounts.map(\.id) == ["id-work", "id-personal"])
        #expect(abs(reloaded.accounts[0].createdAt.timeIntervalSince1970 - 1_700_000_000) < 1)

        // Non-destructive: the legacy value is byte-identical.
        #expect(defaults.data(forKey: "logos.accounts") == legacyData)
    }

    @Test("undecodable legacy data fails safe: empty registry, no index written, legacy preserved")
    @MainActor func undecodableLegacy() throws {
        let url = tempIndexURL()
        let defaults = try freshSuite()
        let garbage = Data("not json at all".utf8)
        defaults.set(garbage, forKey: "logos.accounts")

        let registry = AccountRegistry(indexFileURL: url, legacyDefaults: defaults)

        #expect(registry.accounts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(defaults.data(forKey: "logos.accounts") == garbage)
    }

    @Test("an existing index file wins over legacy data")
    @MainActor func indexFileWins() throws {
        let url = tempIndexURL()
        let defaults = try freshSuite()

        // Seed the index with one account via a plain registry.
        let seed = AccountRegistry(indexFileURL: url)
        try seed.create(label: "from-index")

        // Legacy holds a DIFFERENT list — it must be ignored once the index exists.
        let legacy = [Account(id: "stale", label: "from-legacy", createdAt: Date(timeIntervalSince1970: 0))]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "logos.accounts")

        let registry = AccountRegistry(indexFileURL: url, legacyDefaults: defaults)
        #expect(registry.accounts.map(\.label) == ["from-index"])
    }
}
