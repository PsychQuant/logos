import Testing
import Foundation
@testable import Logos

/// #49 Part 1 + Part 2: the status-bar usage model parses OFF the main actor and drops a
/// stale in-flight refresh (newest-wins), so a just-switched account is never clobbered by a
/// slow read for the previous one (Part 1); it also threads the terminal's `--session-id` to
/// the reader so the read is bound to the exact session rather than newest-mtime (Part 2).
/// These tests inject a gated reader so the refresh ordering is deterministic rather than
/// timing-dependent.
@Suite("WindowUsageModel", .serialized)
@MainActor
struct WindowUsageModelTests {

    /// One recorded reader invocation — lets a test assert exactly which `(configDir, sessionId)`
    /// pair a refresh dispatched (Part 2 threads the session id through this seam).
    struct Call: Equatable {
        let configDir: String
        let sessionId: String?
    }

    /// A reader whose per-configDir completion the test controls. All access is on the
    /// main actor (the model is `@MainActor`; its refresh Task inherits that isolation),
    /// so the plain dictionaries are race-free. `@MainActor` makes it `Sendable`, which the
    /// `@Sendable` `Reader` closure capturing it requires.
    ///
    /// The refresh `Task` is *scheduled* by `track()` / `setSessionId()` but does not run until
    /// the test next suspends, so the test MUST `await entered(_:)` before `release(_:)` —
    /// otherwise the release races ahead of the reader registering its continuation and is lost,
    /// parking the reader forever (release-before-register deadlock). `entered(_:)` is that
    /// handshake, and it is **per-refresh**: it gates on a live `pending` continuation rather
    /// than a once-and-stays flag, so a SECOND refresh on the same configDir (Part 2's
    /// `setSessionId`) is awaited correctly instead of returning against the first read's stale
    /// entry.
    @MainActor
    final class GatedReader {
        private(set) var calls: [Call] = []
        private var pending: [String: CheckedContinuation<WindowUsageModel.Snapshot?, Never>] = [:]
        private var enteredWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        /// The injected read: records the call, stores its continuation under `configDir`
        /// (setting `pending` BEFORE waking any `entered` waiter so the waiter observes a live
        /// continuation), then suspends until the test `release`s it.
        func read(_ configDir: String, _ sessionId: String?) async -> WindowUsageModel.Snapshot? {
            calls.append(Call(configDir: configDir, sessionId: sessionId))
            return await withCheckedContinuation { cont in
                pending[configDir] = cont
                enteredWaiters.removeValue(forKey: configDir)?.forEach { $0.resume() }
            }
        }

        /// Suspends until `read(configDir, _)` has been entered and its continuation stored, so a
        /// subsequent `release` is guaranteed to land. Returns immediately if a read is already
        /// pending for this key (handles the case where the reader ran before the test awaited).
        func entered(_ configDir: String) async {
            if pending[configDir] != nil { return }
            await withCheckedContinuation { enteredWaiters[configDir, default: []].append($0) }
        }

        func release(_ configDir: String, _ snapshot: WindowUsageModel.Snapshot?) {
            pending.removeValue(forKey: configDir)?.resume(returning: snapshot)
        }
    }

    // MARK: - Part 1: off-main + newest-wins

    @Test("a current refresh applies its snapshot off-main")
    func currentRefreshApplies() async {
        let gate = GatedReader()
        let model = WindowUsageModel(read: { configDir, sessionId in await gate.read(configDir, sessionId) })

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
        let model = WindowUsageModel(read: { configDir, sessionId in await gate.read(configDir, sessionId) })

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

    // MARK: - Part 2: session-id binding

    @Test("setSessionId threads the bound id into the reader")
    func setSessionIdThreadsId() async {
        let gate = GatedReader()
        let model = WindowUsageModel(read: { configDir, sessionId in await gate.read(configDir, sessionId) })

        // First read (from track) is unbound — no session id yet.
        model.track(configDir: "A")
        await gate.entered("A")
        gate.release("A", nil)
        await model.inFlightRefresh?.value

        // Binding the session id triggers a fresh refresh that carries it to the reader.
        model.setSessionId("session-1")
        await gate.entered("A")
        gate.release("A", WindowUsageModel.Snapshot(contextTokens: 42, contextMax: 200_000))
        await model.inFlightRefresh?.value

        #expect(gate.calls == [
            Call(configDir: "A", sessionId: nil),
            Call(configDir: "A", sessionId: "session-1"),
        ])
        #expect(model.contextTokens == 42)
    }

    @Test("track(configDir:) clears a previously-bound session id")
    func trackClearsSessionId() async {
        let gate = GatedReader()
        let model = WindowUsageModel(read: { configDir, sessionId in await gate.read(configDir, sessionId) })

        model.track(configDir: "A")
        await gate.entered("A")
        gate.release("A", nil)
        await model.inFlightRefresh?.value

        model.setSessionId("session-1")
        await gate.entered("A")
        gate.release("A", nil)
        await model.inFlightRefresh?.value

        // Switching accounts spawns a NEW claude session; the bound id must be cleared so the
        // next read for account B never targets account A's transcript by id.
        model.track(configDir: "B")
        await gate.entered("B")
        gate.release("B", nil)
        await model.inFlightRefresh?.value

        #expect(gate.calls.last == Call(configDir: "B", sessionId: nil))
    }
}
