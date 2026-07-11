import Foundation
import Testing
@testable import LogosUsage
import LogosAccounts

/// The Logos usage window's model (merge-multistats-into-logos, spec
/// usage-display: "The Logos usage window renders the registry"). Consumer, not
/// discoverer: accounts come from the shared registry, never from filesystem
/// discovery. Keychain reads are hash-suffixed for isolated accounts; the
/// system-default ("Main") account (#54/#55) READS the bare `Claude
/// Code-credentials` entry (read-only) to show its plan usage — see
/// `systemDefaultReadsBareEntry`. The bare entry is never mutated.
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

    // #55 C3: each row carries its registry account id so the usage window can
    // highlight the launcher's active selection (the row's own `id` is a config-dir
    // path, not the registry id — they'd never match).
    @Test("each row carries its registry account id (#55 C3)")
    func rowsCarryRegistryAccountId() throws {
        let registry = makeRegistry()
        let work = try registry.create(label: "work")
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))

        let model = RegistryUsageModel(registry: registry)
        model.load()

        let workRow = try #require(model.accounts.first { $0.label == "work" })
        #expect(workRow.registryAccountId == work.id)
        let mainRow = try #require(model.accounts.first { $0.label == "Main" })
        #expect(mainRow.registryAccountId == Account.systemDefaultID)
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

    // #55 C1: the system-default ("Main") account reuses ~/.claude — its usage row
    // must be built with isDefault:true (→ bare `Claude Code-credentials` keychain)
    // and configDir = ~/.claude, NOT the never-materialized per-account dir. Isolated
    // rows are unchanged.
    @Test("system-default account builds an isDefault:true row against ~/.claude (#55 C1)")
    func systemDefaultRowReadsBareClaude() throws {
        let registry = makeRegistry()
        try registry.create(label: "work")                                            // isolated
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))

        var captured: [(DiscoveredAccount, String)] = []
        let model = RegistryUsageModel(registry: registry) { account, label, _ in
            captured.append((account, label))
            return AccountUsageModel(account: account, labelOverride: label)
        }
        model.load()

        let main = try #require(captured.first { $0.1 == "Main" })
        #expect(main.0.isDefault == true)                                             // → bare keychain
        #expect(main.0.configDir.path.hasSuffix("/.claude"))
        #expect(!main.0.configDir.path.contains("/.logos/accounts/"))                 // real ~/.claude, not per-account
        let work = try #require(captured.first { $0.1 == "work" })
        #expect(work.0.isDefault == false)                                            // isolated unchanged
        #expect(work.0.configDir.path.contains("/.logos/accounts/"))
    }

    // #55 C1: the Main row's keychain lookup must hit the BARE entry (the whole point).
    @Test("system-default account reads the bare Claude Code-credentials entry (#55 C1)")
    func systemDefaultReadsBareEntry() async throws {
        let registry = makeRegistry()
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))

        let recorder = ServiceRecordingKeychain()
        let model = RegistryUsageModel(registry: registry) { account, label, _ in
            AccountUsageModel(
                account: account, labelOverride: label,
                credentialsReader: KeychainCredentialsReader(keychain: recorder),
                usageClient: UsageClient(fetcher: NoopFetcher()))
        }
        model.load()
        await model.refreshAll()

        #expect(recorder.requestedServices == ["Claude Code-credentials"])            // bare, no hash suffix
    }

    // ISOLATED accounts only: their lookups are hash-suffixed. (The system-default
    // exception — reading the bare entry — is covered by `systemDefaultReadsBareEntry`.)
    @Test("every ISOLATED account's Keychain lookup uses a hash-suffixed service")
    func neverReadsBareEntry() async throws {
        let registry = makeRegistry()
        try registry.create(label: "work")
        try registry.create(label: "personal")

        let recorder = ServiceRecordingKeychain()
        let model = RegistryUsageModel(registry: registry) { account, label, _ in
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

    // #51: same coalescing guard as `AccountsModel` — two `refreshAll()` calls
    // overlapping on the first pass must share one serialized pass, or their two
    // serialized loops interleave and the per-account authorization dialogs stack.
    @Test("overlapping first-pass refreshes coalesce and never stack keychain reads (#51)")
    func concurrentFirstPassesCoalesce() async throws {
        let registry = makeRegistry()
        try registry.create(label: "work")
        try registry.create(label: "personal")
        try registry.create(label: "spare")

        let keychain = InFlightTrackingKeychain()
        let model = RegistryUsageModel(registry: registry) { account, label, _ in
            AccountUsageModel(
                account: account,
                labelOverride: label,
                credentialsReader: KeychainCredentialsReader(keychain: keychain),
                usageClient: UsageClient(fetcher: NoopFetcher()))
        }
        model.load()
        #expect(model.accounts.count == 3)

        async let first: Void = model.refreshAll()
        async let second: Void = model.refreshAll()
        _ = await (first, second)

        #expect(keychain.maxInFlight == 1,
                "overlapping first passes must coalesce, not re-stack authorization dialogs")
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

/// Holds each synchronous read open briefly and records the maximum overlap —
/// the observable proxy for "how many authorization dialogs could stack" (#51).
private final class InFlightTrackingKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxObserved = 0

    var maxInFlight: Int { lock.withLock { maxObserved } }

    func readGenericPassword(service: String) -> Data? {
        lock.withLock {
            inFlight += 1
            maxObserved = max(maxObserved, inFlight)
        }
        Thread.sleep(forTimeInterval: 0.08)   // hold the read open to catch overlap
        lock.withLock { inFlight -= 1 }
        return nil
    }
}
