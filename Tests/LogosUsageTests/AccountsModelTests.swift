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

        let model = AccountsModel(home: home) { account in
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
