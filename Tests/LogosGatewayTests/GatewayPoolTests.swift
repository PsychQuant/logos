import Foundation
import Testing
import LogosAccounts
@testable import LogosGateway

/// Counts launches and terminations without spawning anything, so refcount
/// semantics are provable in microseconds rather than seconds.
private actor StubLauncher {
    private(set) var launched: [String] = []
    private(set) var terminated: [String] = []
    /// Descriptors as the pool actually built them — lets a test assert on the
    /// port and state directory each account was handed.
    private(set) var descriptors: [GatewayDescriptor] = []

    var shouldFail = false

    func fail() { shouldFail = true }

    func launch(_ descriptor: GatewayDescriptor) async throws {
        if shouldFail { throw GatewayProcessError.launchFailed("stubbed failure") }
        launched.append(descriptor.accountID)
        descriptors.append(descriptor)
    }

    func terminate(_ accountID: String) async {
        terminated.append(accountID)
    }
}

@Suite struct GatewayPoolTests {

    private func isolatedAccount(id: String = "ACC-1") -> Account {
        Account(id: id, label: "Work", isSystemDefault: false)
    }

    private func makePool(stub: StubLauncher, linger: Duration = .zero) -> GatewayPool {
        GatewayPool(
            allocator: PortAllocator(),
            linger: linger,
            launch: { descriptor in try await stub.launch(descriptor) },
            terminate: { accountID in await stub.terminate(accountID) }
        )
    }

    private let anyCommand = ["/usr/bin/true"]

    /// The system-default account is excluded by design: its settings come from the
    /// user's global ~/.claude/settings.json, whose `env` block outranks any process
    /// env Logos injects, and #54 forbids Logos writing there.
    @Test func systemDefaultAccountGetsNoGateway() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)
        let main = Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true)

        let url = try await pool.acquire(account: main, command: anyCommand, upstream: nil)

        #expect(url == nil)
        #expect(await stub.launched.isEmpty)
    }

    @Test func twoAcquiresShareOneGateway() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)
        let account = isolatedAccount()

        let first = try await pool.acquire(account: account, command: anyCommand, upstream: nil)
        let second = try await pool.acquire(account: account, command: anyCommand, upstream: nil)

        #expect(first != nil)
        #expect(first == second)
        #expect(await stub.launched == ["ACC-1"])
    }

    @Test func gatewaySurvivesUntilTheLastRelease() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)
        let account = isolatedAccount()

        _ = try await pool.acquire(account: account, command: anyCommand, upstream: nil)
        _ = try await pool.acquire(account: account, command: anyCommand, upstream: nil)

        await pool.release(accountID: "ACC-1")
        #expect(await stub.terminated.isEmpty)
        #expect(await pool.activeAccountIDs.contains("ACC-1"))

        await pool.release(accountID: "ACC-1")
        #expect(await stub.terminated == ["ACC-1"])
        #expect(await pool.activeAccountIDs.isEmpty)
    }

    /// Two accounts must never share a port or a state directory — that sharing IS
    /// the cross-account throttling this feature removes.
    @Test func distinctAccountsGetDistinctPortsAndStateDirs() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)

        let a = try await pool.acquire(
            account: isolatedAccount(id: "ACC-A"), command: anyCommand, upstream: nil)
        let b = try await pool.acquire(
            account: isolatedAccount(id: "ACC-B"), command: anyCommand, upstream: nil)

        #expect(a != nil)
        #expect(b != nil)
        #expect(a != b)

        let descriptors = await stub.descriptors
        #expect(descriptors.count == 2)
        #expect(descriptors[0].port != descriptors[1].port)
        #expect(descriptors[0].stateDirectory != descriptors[1].stateDirectory)
    }

    /// A per-account upstream must reach the descriptor, or fail-closed routing
    /// would be enforced against an upstream that was never actually applied.
    @Test func customUpstreamReachesTheDescriptor() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)
        let custom = URL(string: "https://gateway.example.com")!

        _ = try await pool.acquire(
            account: isolatedAccount(), command: anyCommand, upstream: custom)

        #expect(await stub.descriptors.first?.upstream == custom)
    }

    /// shutdown ignores the refcount — it is the account-removal path, and must stop
    /// the child BEFORE AccountReaper deletes its working directory.
    @Test func shutdownTerminatesRegardlessOfRefcount() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)
        let account = isolatedAccount()

        _ = try await pool.acquire(account: account, command: anyCommand, upstream: nil)
        _ = try await pool.acquire(account: account, command: anyCommand, upstream: nil)

        await pool.shutdown(accountID: "ACC-1")

        #expect(await stub.terminated == ["ACC-1"])
        #expect(await pool.activeAccountIDs.isEmpty)
    }

    @Test func shutdownAllStopsEveryGateway() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)

        _ = try await pool.acquire(
            account: isolatedAccount(id: "ACC-A"), command: anyCommand, upstream: nil)
        _ = try await pool.acquire(
            account: isolatedAccount(id: "ACC-B"), command: anyCommand, upstream: nil)

        await pool.shutdownAll()

        #expect(await pool.activeAccountIDs.isEmpty)
        #expect(Set(await stub.terminated) == ["ACC-A", "ACC-B"])
    }

    /// A nil command means no gateway is configured; the caller's failure policy
    /// decides what that means for the account.
    @Test func nilCommandYieldsNoGateway() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)

        let url = try await pool.acquire(
            account: isolatedAccount(), command: nil, upstream: nil)

        #expect(url == nil)
        #expect(await stub.launched.isEmpty)
    }

    /// A failed launch must not leave a half-registered entry, or the next acquire
    /// would hand back a base URL pointing at a gateway that never started.
    @Test func failedLaunchLeavesNoEntry() async throws {
        let stub = StubLauncher()
        await stub.fail()
        let pool = makePool(stub: stub)

        await #expect(throws: GatewayProcessError.self) {
            try await pool.acquire(
                account: isolatedAccount(), command: anyCommand, upstream: nil)
        }
        #expect(await pool.activeAccountIDs.isEmpty)
    }

    /// At refcount zero the gateway lingers instead of dying immediately, so an
    /// account switch or window reopen reuses it rather than paying spawn plus
    /// readiness again.
    @Test func lingersBeforeTearingDown() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub, linger: .milliseconds(400))

        _ = try await pool.acquire(account: isolatedAccount(), command: anyCommand, upstream: nil)
        await pool.release(accountID: "ACC-1")

        // Still alive immediately after the last release.
        #expect(await stub.terminated.isEmpty)

        try await Task.sleep(for: .seconds(1))
        #expect(await stub.terminated == ["ACC-1"])
    }

    /// Re-acquiring during the linger must cancel the pending teardown AND reuse the
    /// same gateway — otherwise a fast switch back would kill a gateway the user is
    /// about to depend on.
    @Test func reacquireDuringLingerCancelsTeardown() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub, linger: .milliseconds(400))
        let account = isolatedAccount()

        let first = try await pool.acquire(account: account, command: anyCommand, upstream: nil)
        await pool.release(accountID: "ACC-1")
        let second = try await pool.acquire(account: account, command: anyCommand, upstream: nil)

        try await Task.sleep(for: .seconds(1))

        #expect(second == first, "re-acquire should reuse the lingering gateway")
        #expect(await stub.launched == ["ACC-1"], "re-acquire should not spawn a second child")
        #expect(await stub.terminated.isEmpty, "pending teardown was not cancelled")
    }
}
