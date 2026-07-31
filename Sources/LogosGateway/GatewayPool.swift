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

        if var existing = entries[account.id] {
            existing.lingerTask?.cancel()
            existing.lingerTask = nil
            existing.refcount += 1
            entries[account.id] = existing
            return existing.baseURL
        }

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
            // half-registered entry would hand the next caller a base URL pointing
            // at a gateway that never started.
            await allocator.release(port)
            GatewayLog.pool.error(
                "gateway launch failed — account=\(account.id, privacy: .public)"
            )
            throw error
        }

        entries[account.id] = Entry(
            refcount: 1, baseURL: descriptor.baseURL, port: port, lingerTask: nil)
        GatewayLog.pool.notice(
            "gateway acquired — account=\(account.id, privacy: .public) port=\(port, privacy: .public)"
        )
        return descriptor.baseURL
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

    func store(_ process: GatewayProcess, for accountID: String) {
        processes[accountID] = process
    }

    func terminate(_ accountID: String) async {
        guard let process = processes.removeValue(forKey: accountID) else { return }
        await process.terminate()
    }
}
