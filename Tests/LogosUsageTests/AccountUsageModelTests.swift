import Foundation
import Testing
@testable import LogosUsage
import LogosAccounts

/// In-memory Keychain backend keyed by service name.
private struct StubKeychain: KeychainReading {
    let store: [String: Data]
    func readGenericPassword(service: String) -> Data? { store[service] }
}

/// Canned usage fetcher: fixed body + status, or a thrown transport error.
private struct StubFetcher: UsageFetching {
    var body: Data = Data()
    var status: Int = 200
    var throwsTransport = false

    func fetch(accessToken: String) async throws -> (Data, Int) {
        if throwsTransport { throw URLError(.notConnectedToInternet) }
        return (body, status)
    }
}

/// Wraps a fetcher and counts calls — proves the read-only discipline
/// ("Keychain credential access is strictly read-only"): an expired token must
/// short-circuit with ZERO network activity, never a refresh attempt.
private final class CountingFetcher: UsageFetching, @unchecked Sendable {
    private let inner: StubFetcher
    private let lock = NSLock()
    private var count = 0

    var fetchCount: Int { lock.withLock { count } }

    init(_ inner: StubFetcher) { self.inner = inner }

    func fetch(accessToken: String) async throws -> (Data, Int) {
        lock.withLock { count += 1 }
        return try await inner.fetch(accessToken: accessToken)
    }
}

/// Serves two overlapping fetches so an OLDER in-flight refresh resolves AFTER
/// a newer one: the first fetch to arrive is held until the second has been
/// served (and returns `firstBody`), the second returns `secondBody` at once and
/// releases the first. Deterministic, no sleeps — pins the generation-token
/// ordering: whichever refresh started first (lower generation) completes last.
private actor ReorderingFetcher: UsageFetching {
    private let firstBody: Data
    private let secondBody: Data
    private var callCount = 0
    private var firstCallArrived = false
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirst: CheckedContinuation<Void, Never>?

    init(firstBody: Data, secondBody: Data) {
        self.firstBody = firstBody
        self.secondBody = secondBody
    }

    /// Resolves once the first fetch is parked inside `fetch` — the point at
    /// which it is safe to launch the second (newer) refresh.
    func waitForFirstCall() async {
        if firstCallArrived { return }
        await withCheckedContinuation { firstCallWaiters.append($0) }
    }

    func fetch(accessToken: String) async throws -> (Data, Int) {
        callCount += 1
        if callCount == 1 {
            firstCallArrived = true
            firstCallWaiters.forEach { $0.resume() }
            firstCallWaiters.removeAll()
            await withCheckedContinuation { releaseFirst = $0 }
            return (firstBody, 200)
        }
        releaseFirst?.resume()
        releaseFirst = nil
        return (secondBody, 200)
    }
}

@MainActor
@Suite("AccountUsageModel.refresh")
struct AccountUsageModelTests {
    private static let usageJSON = Data(#"""
    {
      "five_hour": {"utilization": 24.0, "resets_at": "2026-07-02T16:39:59.942822+00:00"},
      "seven_day": {"utilization": 44.0, "resets_at": "2026-07-06T00:00:00.000000+00:00"}
    }
    """#.utf8)

    /// Builds a model for a fixed account, wiring the stub Keychain to the
    /// account's resolved service name so credential lookup succeeds.
    private func makeModel(
        credsJSON: Data?,
        fetcher: any UsageFetching
    ) -> AccountUsageModel {
        let account = DiscoveredAccount(
            configDir: URL(fileURLWithPath: "/home/test/.claude"),
            isDefault: false,
            identity: AccountIdentity(emailAddress: "t@example.com", userRateLimitTier: "max_20x"))
        let service = ClaudeKeychain.serviceName(
            forConfigDir: account.configDir, isDefault: account.isDefault)
        let store = credsJSON.map { [service: $0] } ?? [:]
        return AccountUsageModel(
            account: account,
            credentialsReader: KeychainCredentialsReader(keychain: StubKeychain(store: store)),
            usageClient: UsageClient(fetcher: fetcher))
    }

    /// Credentials JSON with a far-future expiry so the pre-flight check passes.
    private static func credsJSON(expiresAt: Double) -> Data {
        Data(#"{"claudeAiOauth": {"accessToken": "tok", "expiresAt": \#(Int(expiresAt))}}"#.utf8)
    }

    @Test("valid creds + 200 → loaded with the decoded windows")
    func loadsUsage() async throws {
        let model = makeModel(
            credsJSON: Self.credsJSON(expiresAt: 4_000_000_000_000), // year ~2096, ms
            fetcher: StubFetcher(body: Self.usageJSON, status: 200))
        await model.refresh()
        guard case let .loaded(usage, _) = model.state else {
            Issue.record("expected .loaded, got \(model.state)")
            return
        }
        #expect(usage.windows.map(\.id) == ["five_hour", "seven_day"])
    }

    @Test("an older in-flight refresh does not clobber a newer one")
    func staleRefreshDoesNotClobber() async throws {
        // Distinct bodies: the older refresh carries 11.0, the newer carries 99.0.
        let firstBody = Data(#"{"five_hour": {"utilization": 11.0}}"#.utf8)
        let secondBody = Data(#"{"five_hour": {"utilization": 99.0}}"#.utf8)
        let fetcher = ReorderingFetcher(firstBody: firstBody, secondBody: secondBody)
        let model = makeModel(
            credsJSON: Self.credsJSON(expiresAt: 4_000_000_000_000),
            fetcher: fetcher)

        // R1 (generation 1) reaches the fetcher and parks there.
        let r1 = Task { await model.refresh() }
        await fetcher.waitForFirstCall()
        // R2 (generation 2) resolves at once and releases R1's now-stale response.
        let r2 = Task { await model.refresh() }
        await r2.value
        await r1.value

        guard case let .loaded(usage, _) = model.state else {
            Issue.record("expected .loaded, got \(model.state)")
            return
        }
        // Newest-wins: the later refresh's body survives; the older, slower
        // response that resolved last must not overwrite it.
        #expect(usage.windows.first { $0.id == "five_hour" }?.utilization == 99.0)
    }

    @Test("no Keychain item → noCredentials")
    func noCredentials() async {
        let model = makeModel(credsJSON: nil, fetcher: StubFetcher())
        await model.refresh()
        #expect(model.state == .noCredentials)
    }

    @Test("expired token is caught before any network call → needsLogin")
    func expiredTokenShortCircuits() async {
        // resets_at far in the past; a 200 body is present but must be ignored.
        let model = makeModel(
            credsJSON: Self.credsJSON(expiresAt: 1_000), // 1970, long expired
            fetcher: StubFetcher(body: Self.usageJSON, status: 200))
        await model.refresh()
        #expect(model.state == .needsLogin)
    }

    @Test("expired token → needsLogin with ZERO network fetches (no refresh path)")
    func expiredTokenZeroFetches() async {
        let counting = CountingFetcher(StubFetcher(body: Self.usageJSON, status: 200))
        let model = makeModel(credsJSON: Self.credsJSON(expiresAt: 1_000), fetcher: counting)
        await model.refresh()
        #expect(model.state == .needsLogin)
        #expect(counting.fetchCount == 0)
    }

    @Test("unknown expiry defers to the endpoint — exactly one fetch, 401 decides")
    func unknownExpiryDefersToEndpoint() async {
        let counting = CountingFetcher(StubFetcher(status: 401))
        let credsWithoutExpiry = Data(#"{"claudeAiOauth": {"accessToken": "tok"}}"#.utf8)
        let model = makeModel(credsJSON: credsWithoutExpiry, fetcher: counting)
        await model.refresh()
        #expect(model.state == .needsLogin)
        #expect(counting.fetchCount == 1)
    }

    @Test("401 from the endpoint → needsLogin")
    func unauthorizedMapsToNeedsLogin() async {
        let model = makeModel(
            credsJSON: Self.credsJSON(expiresAt: 4_000_000_000_000),
            fetcher: StubFetcher(status: 401))
        await model.refresh()
        #expect(model.state == .needsLogin)
    }

    @Test("500 from the endpoint → failed")
    func serverErrorMapsToFailed() async {
        let model = makeModel(
            credsJSON: Self.credsJSON(expiresAt: 4_000_000_000_000),
            fetcher: StubFetcher(status: 500))
        await model.refresh()
        guard case .failed = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
    }

    @Test("tier prefers user rate-limit tier")
    func tierPrefersUserTier() {
        let identity = AccountIdentity(
            userRateLimitTier: "max_20x", organizationRateLimitTier: "org", seatTier: "seat")
        #expect(AccountUsageModel.tier(from: identity) == "max_20x")
        #expect(AccountUsageModel.tier(from: AccountIdentity(seatTier: "seat")) == "seat")
        #expect(AccountUsageModel.tier(from: nil) == nil)
    }
}
