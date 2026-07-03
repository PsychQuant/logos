import Foundation
import Testing
@testable import MultiStatsCore

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
        fetcher: StubFetcher
    ) -> AccountUsageModel {
        let account = Account(
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
