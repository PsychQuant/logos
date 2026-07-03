import Foundation
import Testing
@testable import LogosUsage
import LogosAccounts

/// The Logos usage window's model (merge-multistats-into-logos, spec
/// usage-display: "The Logos usage window renders the registry" + the
/// account-credential-isolation delta: the window never touches the bare
/// Keychain entry). Consumer, not discoverer: accounts come from the shared
/// registry, never from filesystem discovery.
@MainActor
@Suite("RegistryUsageModel")
struct RegistryUsageModelTests {

    private func makeRegistry() -> AccountRegistry {
        AccountRegistry(indexFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-usage-tests-\(UUID().uuidString)")
            .appendingPathComponent("index.json"))
    }

    @Test("listed accounts equal the registry — same ids, labels, order")
    func rendersTheRegistry() throws {
        let registry = makeRegistry()
        let work = try registry.create(label: "work")
        let personal = try registry.create(label: "personal")

        let model = RegistryUsageModel(registry: registry)
        model.load()

        #expect(model.accounts.count == 2)
        // Registry labels win over identity-derived labels.
        #expect(model.accounts.map(\.label) == ["work", "personal"])
        // Each row is keyed to the registry account's config dir.
        #expect(model.accounts[0].id.hasSuffix("/accounts/\(work.id)/.claude"))
        #expect(model.accounts[1].id.hasSuffix("/accounts/\(personal.id)/.claude"))
    }

    @Test("a registry mutation is reflected on the next load")
    func reflectsRegistryMutations() throws {
        let registry = makeRegistry()
        try registry.create(label: "work")
        let model = RegistryUsageModel(registry: registry)
        model.load()
        #expect(model.accounts.count == 1)

        try registry.create(label: "personal")
        model.load()
        #expect(model.accounts.map(\.label) == ["work", "personal"])
    }

    @Test("every Keychain lookup uses a hash-suffixed service — never the bare entry")
    func neverReadsBareEntry() async throws {
        let registry = makeRegistry()
        try registry.create(label: "work")
        try registry.create(label: "personal")

        let recorder = ServiceRecordingKeychain()
        let model = RegistryUsageModel(registry: registry) { account, label in
            AccountUsageModel(
                account: account,
                labelOverride: label,
                credentialsReader: KeychainCredentialsReader(keychain: recorder),
                usageClient: UsageClient(fetcher: NoopFetcher()))
        }
        model.load()
        await model.refreshAll()

        let services = recorder.requestedServices
        #expect(services.count == 2)
        for service in services {
            #expect(service != "Claude Code-credentials", "the bare entry must never be read")
            #expect(service.hasPrefix("Claude Code-credentials-"))
            let suffix = service.replacingOccurrences(of: "Claude Code-credentials-", with: "")
            #expect(suffix.count == 8)
            #expect(suffix.allSatisfy { "0123456789abcdef".contains($0) })
        }
    }
}

private struct NoopFetcher: UsageFetching {
    func fetch(accessToken: String) async throws -> (Data, Int) { (Data(), 200) }
}

private final class ServiceRecordingKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var services: [String] = []

    var requestedServices: [String] { lock.withLock { services } }

    func readGenericPassword(service: String) -> Data? {
        lock.withLock { services.append(service) }
        return nil
    }
}
