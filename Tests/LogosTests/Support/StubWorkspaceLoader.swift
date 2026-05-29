import Foundation
@testable import Logos

// Deterministic test double for `WorkspaceLoading` (Issue #15).
//
// The four cluster-B paths under test (epoch-flicker guard, running-walk
// cancel, per-child generic catch, superseded-fail race guard) are all timing
// sensitive: they depend on the relative ordering of two concurrent loads, or
// on a load being suspended at a precise point. Driving them with `Task.sleep`
// would be a flaky timing race. Instead this stub coordinates every load with
// explicit continuation handshakes inside an `actor`, so the test controls
// exactly when each load arrives and when it is released — no sleeps, fully
// deterministic.

/// What a released load produces.
enum StubLoadOutcome: Sendable {
    /// Resolve with this tree.
    case success(FileNode)
    /// Throw this error (boxed for `Sendable`).
    case failure(StubError)
}

/// `Sendable` error box so arbitrary `Error` values can cross the actor
/// boundary. Carries either a `WorkspaceLoader.LoaderError` or a plain
/// `NSError`-style code, the two cases the #15 race-guard test needs (a
/// stale-classified `.notFound` and a transient `.unknown`).
enum StubError: Error, Sendable {
    case loader(WorkspaceLoader.LoaderError)
    case transient(domain: String, code: Int)

    var asError: Error {
        switch self {
        case .loader(let e):
            return e
        case .transient(let domain, let code):
            return NSError(domain: domain, code: code)
        }
    }
}

/// Coordinates load arrivals and releases. `loadAsync` registers its arrival
/// (waking any test awaiting `waitUntilInFlight`) and then suspends until the
/// test calls `release`. Immediate-mode paths skip the suspend.
actor LoaderControl {

    /// Per-path outcome to deliver when released, set up-front by the test.
    private var outcomes: [String: StubLoadOutcome] = [:]
    /// Paths configured to resolve immediately (no gate) with their outcome.
    private var immediate: [String: StubLoadOutcome] = [:]

    /// Order in which loads arrived — lets a test assert interleaving.
    private(set) var arrivalOrder: [String] = []

    /// A load that has arrived but not yet been released parks its resume
    /// continuation here, keyed by path.
    private var parked: [String: CheckedContinuation<StubLoadOutcome, Never>] = [:]
    /// Set of paths that have arrived (for `waitUntilInFlight` fast-path).
    private var arrived: Set<String> = []
    /// Tests awaiting a specific path's arrival park here.
    private var arrivalWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    // MARK: - Test-side configuration

    func setGate(_ path: String, outcome: StubLoadOutcome) {
        outcomes[path] = outcome
    }

    func setImmediate(_ path: String, outcome: StubLoadOutcome) {
        immediate[path] = outcome
    }

    // MARK: - Test-side control

    /// Suspends the caller until a gated load for `path` has arrived and parked.
    func waitUntilInFlight(_ path: String) async {
        if arrived.contains(path) { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            arrivalWaiters[path, default: []].append(cont)
        }
    }

    /// Releases a parked gated load for `path`, delivering its configured
    /// outcome. No-op if the load has not parked yet (shouldn't happen in the
    /// tests, which always `waitUntilInFlight` first).
    func release(_ path: String) {
        guard let cont = parked.removeValue(forKey: path) else { return }
        let outcome = outcomes[path] ?? .success(FileNode(path: path, kind: .directory, children: []))
        cont.resume(returning: outcome)
    }

    // MARK: - Loader-side (called from `loadAsync`)

    /// Records the arrival, wakes any arrival-waiters, then either returns an
    /// immediate outcome or parks until the test releases this path.
    func arriveAndAwait(_ path: String) async -> StubLoadOutcome {
        arrivalOrder.append(path)
        arrived.insert(path)
        if let waiters = arrivalWaiters.removeValue(forKey: path) {
            for w in waiters { w.resume() }
        }
        if let outcome = immediate[path] {
            return outcome
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<StubLoadOutcome, Never>) in
            parked[path] = cont
        }
    }
}

/// `WorkspaceLoading` stub routing every load through `LoaderControl`. The
/// sync `load` path is not exercised by the #15 model tests (they all go
/// through `openWorkspaceAsync` -> `loadAsync`), so it returns an empty tree;
/// the async path carries the deterministic handshake.
final class StubWorkspaceLoader: WorkspaceLoading, Sendable {

    let control: LoaderControl

    init(control: LoaderControl) {
        self.control = control
    }

    func load(rootPath: String, isCancelled: @escaping @Sendable () -> Bool) throws -> FileNode {
        // Unused by the async-only #15 model tests; provide a benign tree so the
        // protocol requirement is satisfied without affecting those tests.
        FileNode(path: rootPath, kind: .directory, children: [])
    }

    func loadAsync(rootPath: String) async throws -> FileNode {
        let outcome = await control.arriveAndAwait(rootPath)
        // Honor cooperative cancellation AFTER release so a superseded load that
        // is released by the test still takes the catch-branch race guard path
        // (Task.isCancelled is true once a newer openWorkspaceAsync cancelled it).
        switch outcome {
        case .success(let node):
            return node
        case .failure(let boxed):
            throw boxed.asError
        }
    }
}
