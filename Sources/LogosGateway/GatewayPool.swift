import Foundation
import LogosAccounts

/// Refcounted, lazy pool of per-account gateways.
///
/// Granularity is per ACCOUNT, not per window: two windows on the same account
/// genuinely spend the same quota, so they should share one rate-limit bucket.
/// And not per registered account either — a machine with dozens of accounts runs
/// a gateway only for the few actually in use.
public actor GatewayPool {

    private struct Entry {
        var refcount: Int
        var baseURL: URL
        var port: UInt16
        var lingerTask: Task<Void, Never>?
    }

    private var entries: [String: Entry] = [:]

    /// In-flight starts, keyed by account id.
    ///
    /// Actor mutual exclusion is not cross-`await` atomicity: `acquire` suspends
    /// twice between finding no entry and registering one (port allocation, then
    /// the launch). Without this, two panes acquiring the same account concurrently
    /// each pass the "no entry" check and each start a gateway, and the second
    /// entry overwrites the first — leaking that child for the life of the app.
    /// Observed live in the Track A smoke before this existed.
    private var startTasks: [String: Task<URL, Error>] = [:]

    private let allocator: PortAllocator
    private let linger: Duration
    private let launch: @Sendable (GatewayDescriptor) async throws -> Void
    private let terminate: @Sendable (String) async -> Void

    /// - Parameters:
    ///   - linger: how long a gateway stays alive after its refcount hits zero, so
    ///     an account switch or window reopen reuses it instead of paying spawn plus
    ///     readiness again. Tests pass `.zero` for determinism.
    ///   - launch/terminate: injected so refcount semantics are provable without
    ///     spawning real children.
    public init(
        allocator: PortAllocator = PortAllocator(),
        linger: Duration = .seconds(5),
        launch: (@Sendable (GatewayDescriptor) async throws -> Void)? = nil,
        terminate: (@Sendable (String) async -> Void)? = nil
    ) {
        self.allocator = allocator
        self.linger = linger
        self.launch = launch ?? { descriptor in
            let process = GatewayProcess(descriptor: descriptor)
            try await process.start()
            await GatewayProcessRegistry.shared.store(process, for: descriptor.accountID)
        }
        self.terminate = terminate ?? { accountID in
            await GatewayProcessRegistry.shared.terminate(accountID)
        }
    }

    public var activeAccountIDs: Set<String> { Set(entries.keys) }

    /// Ensure `account` has a running gateway and return its base URL.
    ///
    /// Returns nil — meaning "spawn claude direct, with no gateway" — for the
    /// system-default account, and when no command is configured.
    public func acquire(
        account: Account,
        command: [String]?,
        upstream: URL?
    ) async throws -> URL? {
        guard !account.isSystemDefault else {
            GatewayLog.pool.notice("system-default account excluded from gateway pool")
            return nil
        }
        guard let command, !command.isEmpty else {
            GatewayLog.pool.notice("no gateway command configured")
            return nil
        }

        // No entry yet, and nobody is starting one: become the starter. The task
        // registers the entry ITSELF before returning, so every coalesced waiter
        // resuming from `task.value` is guaranteed to observe it.
        if entries[account.id] == nil, startTasks[account.id] == nil {
            startTasks[account.id] = makeStartTask(
                account: account, command: command, upstream: upstream)
        }

        if let pending = startTasks[account.id] {
            defer { startTasks.removeValue(forKey: account.id) }
            _ = try await pending.value
        }

        // Take a reference. Every caller — starter and coalesced waiter alike —
        // arrives here, so N concurrent acquires yield a refcount of N and one
        // gateway.
        guard var entry = entries[account.id] else { return nil }
        entry.lingerTask?.cancel()
        entry.lingerTask = nil
        entry.refcount += 1
        entries[account.id] = entry
        GatewayLog.pool.notice(
            "gateway acquired — account=\(account.id, privacy: .public) port=\(entry.port, privacy: .public)"
        )
        return entry.baseURL
    }

    /// Allocate, launch, and register — as one unit that concurrent acquires share.
    private func makeStartTask(
        account: Account,
        command: [String],
        upstream: URL?
    ) -> Task<URL, Error> {
        Task { [allocator, launch] in
            let port = try await allocator.allocate()
            let descriptor = GatewayDescriptor(
                accountID: account.id,
                command: command,
                port: port,
                stateDirectory: GatewayDescriptor.stateDirectory(
                    forAccountHome: account.homeDirectoryPath),
                upstream: upstream ?? GatewayDescriptor.defaultUpstream
            )

            do {
                try await launch(descriptor)
            } catch {
                // Release the port rather than leaking it, and register nothing — a
                // half-registered entry would hand the next caller a base URL
                // pointing at a gateway that never started.
                await allocator.release(port)
                GatewayLog.pool.error(
                    "gateway launch failed — account=\(account.id, privacy: .public)"
                )
                throw error
            }

            await self.register(descriptor: descriptor, port: port)
            return descriptor.baseURL
        }
    }

    /// Register a freshly started gateway at refcount ZERO; the caller of `acquire`
    /// takes the first reference. Separated so it runs INSIDE the start task, which
    /// is what makes the entry visible to every coalesced waiter.
    private func register(descriptor: GatewayDescriptor, port: UInt16) {
        entries[descriptor.accountID] = Entry(
            refcount: 0, baseURL: descriptor.baseURL, port: port, lingerTask: nil)
    }

    /// Drop one reference. At zero the gateway lingers briefly before teardown.
    public func release(accountID: String) async {
        guard var entry = entries[accountID] else { return }
        entry.refcount -= 1
        guard entry.refcount <= 0 else {
            entries[accountID] = entry
            return
        }

        if linger == .zero {
            entries[accountID] = entry
            await tearDown(accountID: accountID)
            return
        }

        entry.lingerTask = Task { [linger] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled else { return }
            await self.tearDown(accountID: accountID)
        }
        entries[accountID] = entry
    }

    /// Stop an account's gateway regardless of refcount. Used on account removal,
    /// where the child must die BEFORE AccountReaper deletes its state directory.
    public func shutdown(accountID: String) async {
        entries[accountID]?.lingerTask?.cancel()
        await tearDown(accountID: accountID)
    }

    /// Stop every gateway. Called at app exit so no child is orphaned.
    public func shutdownAll() async {
        for accountID in entries.keys {
            entries[accountID]?.lingerTask?.cancel()
        }
        for accountID in Array(entries.keys) {
            await tearDown(accountID: accountID)
        }
    }

    private func tearDown(accountID: String) async {
        guard let entry = entries.removeValue(forKey: accountID) else { return }
        await terminate(accountID)
        await allocator.release(entry.port)
        GatewayLog.pool.notice("gateway torn down — account=\(accountID, privacy: .public)")
    }
}

/// Holds the live `GatewayProcess` objects for the pool's default (non-injected)
/// launch path. Kept separate so `GatewayPool` stores only value data and stays
/// trivially testable through the injected closures.
actor GatewayProcessRegistry {

    static let shared = GatewayProcessRegistry()

    private var processes: [String: GatewayProcess] = [:]

    /// Defense in depth against a leaked child: overwriting an entry would drop the
    /// previous `GatewayProcess` with its child still running and nothing left
    /// holding a reference to terminate it. `GatewayPool`'s start-coalescing should
    /// make a collision impossible; this makes it non-fatal if it ever is not.
    func store(_ process: GatewayProcess, for accountID: String) async {
        if let previous = processes[accountID] {
            GatewayLog.process.error(
                "replacing a live gateway process — account=\(accountID, privacy: .public)"
            )
            await previous.terminate()
        }
        processes[accountID] = process
    }

    func terminate(_ accountID: String) async {
        guard let process = processes.removeValue(forKey: accountID) else { return }
        await process.terminate()
    }
}
