import Foundation
import Testing
@testable import LogosUsage
import LogosAccounts

/// #81: the coalesced usage-refresh pass runs in an unstructured Task so no single
/// waiter can tear it out from under the others (#51). That severs the pass from
/// its callers' cancellation, so closing the usage window used to leave the fetches
/// running to completion. The fix reference-counts observers and cancels the shared
/// pass only when the LAST one goes away — proven here by observing whether the
/// fetch's own Task sees itself cancelled.
@MainActor
@Suite("Usage refresh cancellation (#81)")
struct RefreshCancellationTests {
    private static let usageJSON = Data(#"""
    {"five_hour": {"utilization": 10.0, "resets_at": "2026-07-02T16:39:59.942822+00:00"}}
    """#.utf8)

    private static let credsJSON = Data(
        #"{"claudeAiOauth": {"accessToken": "tok", "expiresAt": 4000000000000}}"#.utf8)

    /// A temp $HOME holding exactly ONE (default) account, so a refresh pass makes a
    /// single, deterministically-controllable fetch.
    private func makeSingleAccountHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-cancel-tests-\(UUID().uuidString)")
        let defaultDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: defaultDir.appendingPathComponent(".claude.json").path,
            contents: Data("{}".utf8))
        return home
    }

    private func makeModel(fetcher: GateFetcher) throws -> AccountsModel {
        let home = try makeSingleAccountHome()
        let model = AccountsModel(home: home) { account, _ in
            let service = ClaudeKeychain.serviceName(
                forConfigDir: account.configDir, isDefault: account.isDefault)
            return AccountUsageModel(
                account: account,
                credentialsReader: KeychainCredentialsReader(
                    keychain: FixedKeychain(store: [service: Self.credsJSON])),
                usageClient: UsageClient(fetcher: fetcher))
        }
        model.load()
        #expect(model.accounts.count == 1)
        return model
    }

    // #81 (RED before the fix): with only ONE observer, cancelling it must cancel
    // the shared pass — otherwise the in-flight fetch runs to completion in the
    // background after the window is gone. The gate fetcher parks the fetch, we
    // cancel the sole caller, then release; the fetch reports whether its own Task
    // was cancelled by the time it resumes.
    @Test("cancelling the sole observer cancels the shared refresh pass")
    func lastObserverCancelsPass() async throws {
        let fetcher = GateFetcher(body: Self.usageJSON)
        let model = try makeModel(fetcher: fetcher)

        let caller = Task { await model.refreshAll() }
        await fetcher.waitUntilFetching()          // the pass is parked in the fetch
        caller.cancel()                            // the only observer goes away
        // No explicit release: cancelling the shared pass must itself unpark the
        // fetch (as the real URLSession transfer would be). `caller.value` returns
        // only once the pass has fully unwound.
        await caller.value

        #expect(await fetcher.observedCancelled,
                "the shared pass must be cancelled once its last observer is gone")
    }

    // #81 coalescing guard: with TWO observers, cancelling one must NOT cancel the
    // pass — the other still wants the result. The surviving caller must receive a
    // fully-loaded account. (A naive "cancel the pass whenever any waiter leaves"
    // fails this: the fetch would report cancelled and the account would not load.)
    @Test("cancelling one of two observers leaves the pass running for the other")
    func oneOfTwoObserversCancelsNothing() async throws {
        let fetcher = GateFetcher(body: Self.usageJSON)
        let model = try makeModel(fetcher: fetcher)

        let first = Task { await model.refreshAll() }
        let second = Task { await model.refreshAll() }  // coalesces onto the same pass
        await fetcher.waitUntilFetching()               // both observers have joined
        first.cancel()                                  // one leaves; one remains
        await fetcher.releaseFetch()
        await first.value
        await second.value

        #expect(await fetcher.observedCancelled == false,
                "one observer leaving must not cancel a pass another still awaits")
        guard case .loaded = model.accounts[0].state else {
            Issue.record("the surviving observer must receive a loaded account, got \(model.accounts[0].state)")
            return
        }
    }
}

// MARK: - Fakes

private struct FixedKeychain: KeychainReading {
    let store: [String: Data]
    func readGenericPassword(service: String) -> Data? { store[service] }
}

/// Parks a single fetch until it is either explicitly released or its surrounding
/// (shared) Task is cancelled — the observable proxy for "did the model cancel the
/// coalesced pass?". Cancellation is caught by the fetch's OWN cancellation handler
/// (mirroring how the real `URLSession` transfer unparks on cancel), so the record
/// happens as part of cancellation propagation with no cross-executor race, and the
/// cancelled case needs no external release. Deterministic: no sleeps, no timeouts.
private actor GateFetcher: UsageFetching {
    private let body: Data
    private var isParked = false
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    private(set) var observedCancelled = false

    init(body: Data) { self.body = body }

    /// Resolves once the fetch has entered and parked — the point at which it is
    /// safe to cancel a caller and know the pass is genuinely in flight.
    func waitUntilFetching() async {
        if isParked { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    /// Wakes the parked fetch for the non-cancelled path (a surviving observer).
    func releaseFetch() { resumePark() }

    private func resumePark() {
        release?.resume()
        release = nil
    }

    private func noteCancelled() {
        observedCancelled = true
        resumePark()
    }

    func fetch(accessToken: String) async throws -> (Data, Int) {
        isParked = true
        parkWaiters.forEach { $0.resume() }
        parkWaiters.removeAll()
        // Park until released OR the shared Task is cancelled. Cancelling the pass
        // fires this handler synchronously with the cancellation, so `observedCancelled`
        // is recorded before the fetch unparks — no race against an external reader.
        await withTaskCancellationHandler {
            await withCheckedContinuation { release = $0 }
        } onCancel: {
            Task { await self.noteCancelled() }
        }
        return (body, 200)
    }
}
