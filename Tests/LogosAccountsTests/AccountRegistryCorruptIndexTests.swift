import Foundation
import Testing
@testable import LogosAccounts

/// Corrupt-index protection (merge-multistats-into-logos, spec
/// account-registry: "A corrupt index file is never silently destroyed").
/// The failure being designed against is silent data destruction: a parse
/// failure must present as empty WITHOUT touching the file, so the user (or a
/// bug report) can still inspect what was there.
@Suite("AccountRegistry corrupt index")
struct AccountRegistryCorruptIndexTests {

    private func corruptIndex() throws -> (url: URL, bytes: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-corrupt-\(UUID().uuidString)")
            .appendingPathComponent("index.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{\"version\": 1, \"accounts\": [{\"id\": tru".utf8)   // truncated garbage
        try bytes.write(to: url)
        return (url, bytes)
    }

    @Test("corrupt index loads empty and stays byte-identical on disk")
    @MainActor func corruptFilePreserved() throws {
        let (url, bytes) = try corruptIndex()

        let registry = AccountRegistry(indexFileURL: url)

        #expect(registry.accounts.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("corrupt index survives even when legacy migration data is present")
    @MainActor func corruptFileNotClobberedByMigration() throws {
        let (url, bytes) = try corruptIndex()
        let defaults = try #require(UserDefaults(suiteName: "registry-corrupt-\(UUID().uuidString)"))
        defaults.set(
            try JSONEncoder().encode([Account(label: "legacy")]),
            forKey: "logos.accounts")

        let registry = AccountRegistry(indexFileURL: url, legacyDefaults: defaults)

        // The corrupt (existing) file blocks migration — it is evidence, not
        // free space.
        #expect(registry.accounts.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("first explicit user mutation rewrites the corrupt file")
    @MainActor func mutationRewrites() throws {
        let (url, bytes) = try corruptIndex()

        let registry = AccountRegistry(indexFileURL: url)
        try registry.create(label: "fresh")

        let rewritten = try Data(contentsOf: url)
        #expect(rewritten != bytes)
        let reloaded = AccountRegistry(indexFileURL: url)
        #expect(reloaded.accounts.map(\.label) == ["fresh"])
    }
}
