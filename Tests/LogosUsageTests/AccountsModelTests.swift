import Foundation
import Testing
@testable import LogosUsage
import LogosAccounts

/// Fan-out isolation (merge-multistats-into-logos, spec usage-display:
/// "Per-account usage retrieval is isolated" + "Missing or denied credentials
/// surface as a quiet display state"). Discovery runs against a real temp
/// home-dir fixture; per-account keychain/fetcher stubs are routed through the
/// injected model factory.
@MainActor
@Suite("AccountsModel fan-out")
struct AccountsModelTests {

    private static let usageJSON = Data(#"""
    {"five_hour": {"utilization": 10.0, "resets_at": "2026-07-02T16:39:59.942822+00:00"}}
    """#.utf8)

    private static let credsJSON = Data(
        #"{"claudeAiOauth": {"accessToken": "tok", "expiresAt": 4000000000000}}"#.utf8)

    /// A temp $HOME with a default account + two convention accounts.
    private func makeFixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("accounts-model-tests-\(UUID().uuidString)")
        let fm = FileManager.default
        let defaultDir = home.appendingPathComponent(".claude")
        try fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        fm.createFile(atPath: defaultDir.appendingPathComponent(".claude.json").path,
                      contents: Data("{}".utf8))
        for id in ["acc-bad", "acc-nocreds"] {
            let dir = home.appendingPathComponent(".logos/accounts/\(id)/.claude")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: dir.appendingPathComponent(".claude.json").path,
                          contents: Data("{}".utf8))
        }
        return home
    }

    @Test("one failing account leaves the others loaded; denied creds stay quiet")
    func mixedFanOutIsolation() async throws {
        let home = try makeFixtureHome()

        let model = AccountsModel(home: home) { account, _ in
            let service = ClaudeKeychain.serviceName(
                forConfigDir: account.configDir, isDefault: account.isDefault)
            // Route per account: default → 200, acc-bad → 500, acc-nocreds → no item.
            let hasCreds = !account.configDir.path.contains("acc-nocreds")
            let status = account.configDir.path.contains("acc-bad") ? 500 : 200
            return AccountUsageModel(
                account: account,
                credentialsReader: KeychainCredentialsReader(
                    keychain: FixedKeychain(store: hasCreds ? [service: Self.credsJSON] : [:])),
                usageClient: UsageClient(
                    fetcher: FixedFetcher(body: Self.usageJSON, status: status)))
        }

        model.load()
        #expect(model.accounts.count == 3)
        await model.refreshAll()

        let byId = { (fragment: String) in
            model.accounts.first { $0.id.contains(fragment) }
        }
        // The default account loaded despite its siblings failing.
        guard case .loaded = try #require(byId(".claude/")?.state ?? byId("/.claude")?.state) else {
            Issue.record("expected default account .loaded")
            return
        }
        // The 500 account failed — alone.
        guard case .failed = try #require(byId("acc-bad")).state else {
            Issue.record("expected acc-bad .failed")
            return
        }
        // The credential-less account is a quiet display state, not an error.
        #expect(try #require(byId("acc-nocreds")).state == .noCredentials)
    }

    @Test("a denied Keychain read performs exactly one lookup per refresh pass")
    func deniedReadSingleLookup() async {
        let keychain = CountingKeychain(store: [:])   // denied / absent for everything
        let account = DiscoveredAccount(
            configDir: URL(fileURLWithPath: "/home/test/.claude"),
            isDefault: false, identity: nil)
        let model = AccountUsageModel(
            account: account,
            credentialsReader: KeychainCredentialsReader(keychain: keychain),
            usageClient: UsageClient(fetcher: FixedFetcher(body: Data(), status: 200)))

        await model.refresh()
        #expect(model.state == .noCredentials)
        #expect(keychain.lookupCount == 1)   // no hidden retry loop

        // Only an explicit refresh reads again.
        await model.refresh()
        #expect(keychain.lookupCount == 2)
    }
}

extension AccountsModelTests {

    // "The standalone viewer keeps discovery-based parity": registry labels
    // overlay discovered convention accounts when the shared index exists;
    // accounts without a registry entry keep their derived label; the default
    // account never takes a registry label.
    @Test("registry labels overlay discovered convention accounts")
    func registryLabelOverlay() async throws {
        let home = try makeFixtureHome()   // default + acc-bad + acc-nocreds
        let registry = AccountRegistry(indexFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("label-overlay-\(UUID().uuidString)")
            .appendingPathComponent("index.json"))
        try registry.add(Account(id: "acc-bad", label: "工作用"))

        let model = AccountsModel(home: home, labelRegistry: registry)
        model.load()

        #expect(model.accounts.count == 3)
        let labeled = try #require(model.accounts.first { $0.id.contains("acc-bad") })
        #expect(labeled.label == "工作用")
        let unlabeled = try #require(model.accounts.first { $0.id.contains("acc-nocreds") })
        #expect(unlabeled.label == "acc-nocreds")   // derived, no registry entry
        let defaultAccount = try #require(model.accounts.first { $0.isDefault })
        #expect(defaultAccount.label != "工作用")
    }

    // #55 C2: when the registry has a system-default ("Main") entry, the discovered
    // default `~/.claude` row takes that launcher label — so the standalone viewer
    // shows it under the launcher's "Main" identity, not a nil/derived label.
    @Test("the discovered default row takes the registry system-default label (#55 C2)")
    func defaultRowTakesSystemDefaultLabel() async throws {
        let home = try makeFixtureHome()
        let registry = AccountRegistry(indexFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sysdefault-label-\(UUID().uuidString)")
            .appendingPathComponent("index.json"))
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))

        let model = AccountsModel(home: home, labelRegistry: registry)
        model.load()

        let defaultAccount = try #require(model.accounts.first { $0.isDefault })
        #expect(defaultAccount.label == "Main")
    }

    // "First authorization pass serializes Keychain reads": dialogs stack when
    // reads overlap, so the first pass must hold at most one read in flight;
    // concurrency is restored on subsequent (already-authorized) refreshes.
    @Test("first refresh serializes keychain reads; later refreshes run concurrently")
    func firstPassSerialized() async throws {
        let home = try makeFixtureHome()   // three accounts
        let keychain = InFlightTrackingKeychain()
        let model = AccountsModel(home: home) { account, _ in
            AccountUsageModel(
                account: account,
                credentialsReader: KeychainCredentialsReader(keychain: keychain),
                usageClient: UsageClient(fetcher: FixedFetcher(body: Data(), status: 200)))
        }
        model.load()
        #expect(model.accounts.count == 3)

        await model.refreshAll()
        #expect(keychain.maxInFlight == 1, "first pass must never stack authorization dialogs")

        keychain.resetMax()
        await model.refreshAll()
        #expect(keychain.maxInFlight >= 2, "later passes must regain concurrency")
    }

    // #51: the first-pass serialization only holds WITHIN one pass. Two
    // `refreshAll()` calls that overlap on the first pass each start their own
    // serialized loop, so the two loops interleave and the per-account
    // authorization dialogs stack again. Overlapping passes must coalesce onto a
    // single in-flight pass so at most one Keychain read is ever in flight.
    @Test("overlapping first-pass refreshes coalesce and never stack keychain reads (#51)")
    func concurrentFirstPassesCoalesce() async throws {
        let home = try makeFixtureHome()   // three accounts
        let keychain = InFlightTrackingKeychain()
        let model = AccountsModel(home: home) { account, _ in
            AccountUsageModel(
                account: account,
                credentialsReader: KeychainCredentialsReader(keychain: keychain),
                usageClient: UsageClient(fetcher: FixedFetcher(body: Data(), status: 200)))
        }
        model.load()
        #expect(model.accounts.count == 3)

        // Launch two first-pass refreshes concurrently. A second serialized loop
        // running alongside the first would push maxInFlight past 1.
        async let first: Void = model.refreshAll()
        async let second: Void = model.refreshAll()
        _ = await (first, second)

        #expect(keychain.maxInFlight == 1,
                "overlapping first passes must coalesce, not re-stack authorization dialogs")
    }
}

// MARK: - Instrumented fakes

private struct FixedKeychain: KeychainReading {
    let store: [String: Data]
    func readGenericPassword(service: String) -> Data? { store[service] }
}

private struct FixedFetcher: UsageFetching {
    var body: Data
    var status: Int
    func fetch(accessToken: String) async throws -> (Data, Int) { (body, status) }
}

/// Holds each (synchronous) read open briefly and records the maximum number
/// of overlapping reads — the observable proxy for "how many authorization
/// dialogs could stack".
private final class InFlightTrackingKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxObserved = 0

    var maxInFlight: Int { lock.withLock { maxObserved } }

    func resetMax() { lock.withLock { maxObserved = 0 } }

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

private final class CountingKeychain: KeychainReading, @unchecked Sendable {
    private let store: [String: Data]
    private let lock = NSLock()
    private var count = 0

    var lookupCount: Int { lock.withLock { count } }

    init(store: [String: Data]) { self.store = store }

    func readGenericPassword(service: String) -> Data? {
        lock.withLock { count += 1 }
        return store[service]
    }
}
