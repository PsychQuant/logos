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

    // MARK: - #83: a failed read retains last-known-good

    @Test("a nil read (real I/O failure) retains the prior good snapshot, never zeroes it")
    func nilReadRetainsLastGood() async {
        let gate = GatedReader()
        let model = WindowUsageModel(read: { configDir, sessionId in await gate.read(configDir, sessionId) })

        // A first refresh applies a good snapshot.
        model.track(configDir: "A")
        await gate.entered("A")
        gate.release("A", WindowUsageModel.Snapshot(
            contextTokens: 1234, contextMax: 1_000_000,
            sessionCostUSD: Decimal(string: "7.50")!, hasUnpricedModel: false))
        await model.inFlightRefresh?.value
        #expect(model.contextTokens == 1234)
        #expect(model.sessionCostUSD == Decimal(string: "7.50"))

        // A LATER refresh on the SAME account (a re-bind / file-watch fire, NOT a switch) whose
        // read returns nil — the #83 case: `defaultRead` maps a genuine transcript I/O failure
        // to nil. The model MUST retain the prior good values, never zero them. This pins the
        // `guard let snapshot else { return }` retain-last-good invariant: it goes RED against a
        // careless refactor to `snapshot?.contextTokens ?? 0`, which would blank live usage on a
        // transient read failure.
        model.setSessionId("session-1")
        await gate.entered("A")
        gate.release("A", nil)
        await model.inFlightRefresh?.value

        #expect(model.contextTokens == 1234)
        #expect(model.contextMax == 1_000_000)
        #expect(model.sessionCostUSD == Decimal(string: "7.50"))
        #expect(model.hasUnpricedModel == false)
    }

    // MARK: - #89: a fresh session shows empty, never a foreign transcript's numbers

    @Test("a fresh session (bound id with no transcript) shows 0, not a foreign transcript's tokens")
    func freshSessionShowsEmptyNotForeignTranscript() async throws {
        // Drives the PRODUCTION `defaultRead` end to end: the injectable gate returns a canned
        // snapshot and never exercises `transcriptURL`, so proving the fresh-session-shows-empty
        // contract needs the real reader against a real config dir that ALREADY holds a
        // previous/other session's transcript (a decoy with real usage).
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("logos-usage-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("projects/-Users-che-proj")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        let decoy = #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":777,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}"# + "\n"
        try Data(decoy.utf8).write(to: proj.appendingPathComponent("decoy-other-session.jsonl"))

        let model = WindowUsageModel()             // production defaultRead
        model.track(configDir: root.path)          // unbound refresh — pre-#89 would read the decoy
        await model.inFlightRefresh?.value
        model.setSessionId("fresh-uuid-with-no-file")   // bound to an id whose .jsonl doesn't exist
        await model.inFlightRefresh?.value

        // Pre-#89 the newest-mtime fallback resolves the decoy → contextTokens == 777 and a
        // non-zero cost. Fixed: the fresh session resolves to nil → the reset-0 (track's
        // reset-on-switch, retained by #83's `guard let snapshot`) stays → the status bar is empty.
        #expect(model.contextTokens == 0)
        #expect(model.sessionCostUSD == Decimal(string: "0"))

        // `track(configDir:)` starts a real FileWatcher on `root`. The model is still ALIVE here,
        // so #91's deinit backstop hasn't run — stop the watcher explicitly before removing the
        // watched tree, else deleting the dir fires an event into a live watcher mid-test.
        // `track(nil)` is the deterministic teardown: it stops the watcher and starts none.
        // Order matters — stop, THEN remove.
        model.track(configDir: nil)
        try? fm.removeItem(at: root)
    }

    // MARK: - #91: deinit stops the file watcher (UAF backstop)

    @Test("deinit stops the file watcher even if onDisappear never fired")
    func deinitStopsWatcher() async {
        // A spy watcher the TEST holds, so it outlives the model and we can inspect
        // stop-on-teardown. `track()` starts it; releasing the model must stop it (the #91
        // backstop) — otherwise a stray FS event on the account dir would deref the freed
        // FileWatcher (`passUnretained` → use-after-free SIGABRT).
        @MainActor final class SpyWatcher: UsageWatching {
            var stopCount = 0
            func start() {}
            func stop() { stopCount += 1 }
        }
        let spy = SpyWatcher()

        var model: WindowUsageModel? = WindowUsageModel(
            read: { _, _ in nil },
            makeWatcher: { _, _, _ in spy })
        model?.track(configDir: "/tmp/logos-91-watch")   // creates + starts the spy watcher
        #expect(spy.stopCount == 0)                       // still alive → not torn down

        model = nil   // last strong ref gone → isolated deinit → watcher.stop()
        // The isolated deinit runs on the main actor: synchronously when released on-main,
        // otherwise enqueued — yield so a hop drains before the assert.
        for _ in 0..<10 where spy.stopCount == 0 { await Task.yield() }
        #expect(spy.stopCount >= 1)
    }

    // MARK: - #48: session cost

    @Test("a refresh applies the snapshot's session cost and formats it")
    func sessionCostApplied() async {
        let gate = GatedReader()
        let model = WindowUsageModel(read: { configDir, sessionId in await gate.read(configDir, sessionId) })

        model.track(configDir: "A")
        await gate.entered("A")
        gate.release("A", WindowUsageModel.Snapshot(
            contextTokens: 500, contextMax: 200_000,
            sessionCostUSD: Decimal(string: "12.34")!, hasUnpricedModel: false))
        await model.inFlightRefresh?.value

        #expect(model.sessionCostUSD == Decimal(string: "12.34"))
        #expect(model.sessionCostFormatted == "$12.34")
    }

    @Test("an unpriced-model snapshot marks the formatted cost a lower bound")
    func sessionCostUnpricedMarker() async {
        let gate = GatedReader()
        let model = WindowUsageModel(read: { configDir, sessionId in await gate.read(configDir, sessionId) })

        model.track(configDir: "A")
        await gate.entered("A")
        gate.release("A", WindowUsageModel.Snapshot(
            contextTokens: 500, contextMax: 200_000,
            sessionCostUSD: Decimal(string: "5.00")!, hasUnpricedModel: true))
        await model.inFlightRefresh?.value

        #expect(model.sessionCostFormatted == "$5.00+?")   // "+?" = a model had no price → lower bound
    }

    @Test("track(configDir:) resets session cost to zero on switch")
    func trackResetsSessionCost() async {
        let gate = GatedReader()
        let model = WindowUsageModel(read: { configDir, sessionId in await gate.read(configDir, sessionId) })

        model.track(configDir: "A")
        await gate.entered("A")
        gate.release("A", WindowUsageModel.Snapshot(
            contextTokens: 500, contextMax: 200_000,
            sessionCostUSD: Decimal(string: "9.99")!, hasUnpricedModel: false))
        await model.inFlightRefresh?.value
        #expect(model.sessionCostUSD == Decimal(string: "9.99"))

        // Switching to an account with no transcript yet must clear the previous cost so it
        // never lingers (mirrors the #47 token reset-on-switch contract, extended to cost).
        model.track(configDir: "B")
        await gate.entered("B")
        gate.release("B", nil)
        await model.inFlightRefresh?.value

        #expect(model.sessionCostUSD == Decimal(string: "0"))
        #expect(model.sessionCostFormatted == "$0.00")
    }
}
