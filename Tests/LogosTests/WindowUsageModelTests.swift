import Testing
import Foundation
@testable import Logos

/// #49 Part 1: the status-bar usage model now parses OFF the main actor and drops a
/// stale in-flight refresh (newest-wins), so a just-switched account is never clobbered
/// by a slow read for the previous one. These tests inject a gated reader so the refresh
/// ordering is deterministic rather than timing-dependent.
@Suite("WindowUsageModel", .serialized)
@MainActor
struct WindowUsageModelTests {

    /// A reader whose per-configDir completion the test controls. All access is on the
    /// main actor (the model is `@MainActor`; its refresh Task inherits that isolation),
    /// so the plain dictionaries are race-free. `@MainActor` makes it `Sendable`, which the
    /// `@Sendable` `Reader` closure capturing it requires.
    ///
    /// The refresh `Task` is *scheduled* by `track()` but does not run until the test next
    /// suspends, so the test MUST `await entered(_:)` before `release(_:)` — otherwise the
    /// release races ahead of the reader registering its continuation and is lost, parking
    /// the reader forever (release-before-register deadlock). `entered(_:)` is that handshake.
    @MainActor
    final class GatedReader {
        private var pending: [String: CheckedContinuation<WindowUsageModel.Snapshot?, Never>] = [:]
        private var enteredKeys: Set<String> = []
        private var enteredWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        /// The injected read: records that this configDir's read has begun (waking any
        /// `entered(_:)` waiter), then suspends until the test `release`s it.
        func read(_ configDir: String) async -> WindowUsageModel.Snapshot? {
            enteredKeys.insert(configDir)
            enteredWaiters.removeValue(forKey: configDir)?.forEach { $0.resume() }
            return await withCheckedContinuation { pending[configDir] = $0 }
        }

        /// Suspends until `read(configDir)` has been entered and its continuation stored,
        /// so a subsequent `release` is guaranteed to land. Returns immediately if already
        /// entered (handles the case where the reader ran before the test awaited).
        func entered(_ configDir: String) async {
            if enteredKeys.contains(configDir) { return }
            await withCheckedContinuation { enteredWaiters[configDir, default: []].append($0) }
        }

        func release(_ configDir: String, _ snapshot: WindowUsageModel.Snapshot?) {
            pending.removeValue(forKey: configDir)?.resume(returning: snapshot)
        }
    }

    @Test("a current refresh applies its snapshot off-main")
    func currentRefreshApplies() async {
        let gate = GatedReader()
        let model = WindowUsageModel(read: { await gate.read($0) })

        model.track(configDir: "A")
        let task = model.inFlightRefresh
        await gate.entered("A")                 // let the refresh Task register before releasing
        gate.release("A", WindowUsageModel.Snapshot(contextTokens: 500, contextMax: 200_000))
        await task?.value

        #expect(model.contextTokens == 500)
        #expect(model.contextMax == 200_000)
    }

    @Test("a stale in-flight refresh does not clobber a newer account switch")
    func staleRefreshDropped() async {
        let gate = GatedReader()
        let model = WindowUsageModel(read: { await gate.read($0) })

        model.track(configDir: "A")            // gen 1 — parked in the gated reader
        let taskA = model.inFlightRefresh
        await gate.entered("A")
        model.track(configDir: "B")            // gen 2 — resets tokens to 0, parked
        let taskB = model.inFlightRefresh
        await gate.entered("B")

        // The OLD (account A) read completes LATE with a large token count. Because its
        // generation is stale, it must be discarded rather than overwrite account B.
        gate.release("A", WindowUsageModel.Snapshot(contextTokens: 999_999, contextMax: 1_000_000))
        await taskA?.value
        gate.release("B", nil)                 // B has no transcript yet → stays at the reset default
        await taskB?.value

        #expect(model.contextTokens == 0)
        #expect(model.contextMax == 200_000)
    }
}
