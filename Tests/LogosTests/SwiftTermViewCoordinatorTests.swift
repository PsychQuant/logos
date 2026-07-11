import Testing
import Foundation
import LogoSwitch
import LogosAccounts
@testable import Logos

/// End-to-end-at-the-Coordinator-seam tests for the passive 401 re-auth banner
/// (PsychQuant/logos#29/#30): a 401 emitted by the hosted process flips
/// `TerminalSessionState.needsAuth` + forces the active account's needs-reauth
/// (#31), AND it still does so when the signal is split across chunks with an
/// auto-handle `parser.reset()` interleaved (the #30 Item 1 regression).
///
/// The OAuth-authorize-URL test was removed: that detector path (#17) is a dead
/// end being retired by #34's `claude auth login` Sign-in button (#35), and a
/// claude authorize URL has no place in the test suite.
@Suite("SwiftTermView.Coordinator", .serialized)
@MainActor
struct SwiftTermViewCoordinatorTests {

    private func tempRegistry() -> AccountRegistry {
        AccountRegistry(indexFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)")
            .appendingPathComponent("index.json"))
    }

    private func makeCoordinator(engine: AutoHandleEngine) -> SwiftTermView.Coordinator {
        let config = ClaudeProcessConfig(executablePath: "/bin/echo")
        let mgr = AccountManager(registry: tempRegistry(), store: InMemoryActiveAccountStore())
        return SwiftTermView.Coordinator(
            processConfig: config,
            engine: engine,
            accountManager: mgr,
            sessionState: TerminalSessionState(),
            onSessionSpawned: { _ in }
        )
    }

    @Test("a single-chunk 401 flips needsAuth")
    func singleChunkFlipsNeedsAuth() {
        let coord = makeCoordinator(engine: AutoHandleEngine(rules: [], persistence: nil))
        #expect(coord.sessionState.needsAuth == false)
        coord.handleChunk(Array("Please run /login · API Error: 401 Invalid authentication credentials\n".utf8))
        #expect(coord.sessionState.needsAuth == true)
    }

    @Test("a 401 split across chunks survives an interleaved auto-handle reset (#30 Item 1)")
    func splitSignalSurvivesReset() {
        // A rule firing on a sentinel forces `parser.reset()` between the two
        // halves of the 401 line — the precise condition that dropped the first
        // half before #30 routed the detectors through the reset-immune buffer.
        let engine = AutoHandleEngine(
            rules: [AutoHandleRule(id: "r", name: "r", pattern: "RESETNOW", response: "x\n", cooldown: 0.001)],
            persistence: nil
        )
        let coord = makeCoordinator(engine: engine)

        coord.handleChunk(Array("Please run /login\n".utf8))   // /login, no 401 yet
        #expect(coord.sessionState.needsAuth == false)

        coord.handleChunk(Array("RESETNOW\n".utf8))            // rule fires → parser.reset()
        #expect(coord.sessionState.needsAuth == false)

        coord.handleChunk(Array("· API Error: 401\n".utf8))    // 401 arrives AFTER the reset
        // The reset wiped the parser buffer, but detectorBuffer retained the
        // "/login" half, so the co-occurrence is still seen → banner fires.
        #expect(coord.sessionState.needsAuth == true)
    }

    // MARK: - #31 banner auto-clear + needsAuth↔needsReauth coherence

    /// A Coordinator with one active account that hasn't hit a 401 — so
    /// `needsReauth` reads `false` by default (live-401-only, #31), letting the
    /// tests prove the override fires + clears, not just the default.
    private func makeCoordinatorWithAuthedActive() throws
        -> (SwiftTermView.Coordinator, AccountManager, Account) {
        let mgr = AccountManager(registry: tempRegistry(), store: InMemoryActiveAccountStore())
        let acc = try mgr.createAccount(label: "work")   // first account → active
        // #42: the pane spawns claude WITH this account, so the Coordinator's processConfig
        // carries it — the live-401 path forces THIS pane's account (per-window-correct),
        // not the global active. The test must build the config with the account to reflect
        // that contract (pre-#42 it relied on the global active; #42 made it per-window).
        let config = ClaudeProcessConfig(executablePath: "/bin/echo", account: acc)
        let coord = SwiftTermView.Coordinator(
            processConfig: config,
            engine: AutoHandleEngine(rules: [], persistence: nil),
            accountManager: mgr,
            sessionState: TerminalSessionState(),
            onSessionSpawned: { _ in }
        )
        return (coord, mgr, acc)
    }

    @Test("a live 401 forces the active account's needsReauth so the switcher agrees (#31)")
    func liveUnauthForcesSwitcherCoherence() throws {
        let (coord, mgr, acc) = try makeCoordinatorWithAuthedActive()
        #expect(mgr.needsReauth(acc) == false)   // authenticated baseline
        coord.handleChunk(Array("Please run /login · API Error: 401 Invalid authentication credentials\n".utf8))
        #expect(coord.sessionState.needsAuth == true)
        #expect(mgr.needsReauth(acc) == true)    // forced → switcher agrees with the banner
    }

    // MARK: - #49 Part 2: --session-id injection at the spawn seam

    @Test("session spawn args append a fresh --session-id and report it")
    func sessionSpawnArgsAppendsAndReports() {
        let (args, id) = SwiftTermView.Coordinator.sessionSpawnArgs(base: [], sessionId: "uuid-1")
        #expect(args == ["--session-id", "uuid-1"])
        #expect(id == "uuid-1")   // reported → usage binds to this exact session
    }

    @Test("session spawn args preserve caller extra args and still bind the id")
    func sessionSpawnArgsPreservesExtras() {
        let (args, id) = SwiftTermView.Coordinator.sessionSpawnArgs(
            base: ["--dangerously-skip-permissions"], sessionId: "uuid-2")
        #expect(args == ["--dangerously-skip-permissions", "--session-id", "uuid-2"])
        #expect(id == "uuid-2")
    }

    @Test("a caller-supplied --session-id is respected and not double-bound")
    func sessionSpawnArgsRespectsCallerBound() {
        let (args, id) = SwiftTermView.Coordinator.sessionSpawnArgs(
            base: ["--session-id", "caller-owned"], sessionId: "uuid-3")
        #expect(args == ["--session-id", "caller-owned"])   // unchanged — no double --session-id
        #expect(id == nil)                                  // nothing to auto-bind → newest-mtime fallback
    }

    // MARK: - #84: the #78 hosted-unit-test spawn gate (behavioral)

    /// Reference recorder for the spawn side-effects the gate governs: whether the
    /// `spawnProcess` seam fired and whether `onSessionSpawned` reported a bound id.
    /// A class so the coordinator's escaping closures can flip flags the test reads
    /// back afterwards.
    private final class GateProbe {
        var spawned = false
        var reported = false
    }

    /// Wires a Coordinator whose spawn side-effects are replaced by `probe`
    /// recorders, so `attemptStart` can be driven both ways WITHOUT launching a real
    /// process or constructing a `TeedLocalProcessTerminalView` (which segfaults the
    /// bare `swift test` runner). `attemptStart` is the view-free half of
    /// `startIfNeeded` — it holds the entire #78 gate + spawn path.
    private func makeGatedCoordinator(hosted: Bool, probe: GateProbe) -> SwiftTermView.Coordinator {
        let config = ClaudeProcessConfig(executablePath: "/bin/echo")
        let mgr = AccountManager(registry: tempRegistry(), store: InMemoryActiveAccountStore())
        let coord = SwiftTermView.Coordinator(
            processConfig: config,
            engine: AutoHandleEngine(rules: [], persistence: nil),
            accountManager: mgr,
            sessionState: TerminalSessionState(),
            onSessionSpawned: { _ in probe.reported = true }
        )
        // Replace the real PTY spawn with a recorder — asserts "spawn attempted"
        // without ever launching claude (or any process).
        coord.spawnProcess = { _ in probe.spawned = true }
        coord.isHostedUnitTesting = hosted
        return coord
    }

    @Test("the #78 gate blocks the spawn side-effect under hosted unit testing (#84)")
    func hostedGateBlocksSpawn() {
        let probe = GateProbe()
        let coord = makeGatedCoordinator(hosted: true, probe: probe)

        coord.attemptStart()

        #expect(probe.spawned == false)     // returned before the spawn seam
        #expect(probe.reported == false)    // …and before the session-id report
        #expect(coord.hasStarted == false)  // nothing half-initialized
    }

    @Test("a non-hosted process reaches the spawn path (#84)")
    func gateOpenAttemptsSpawn() {
        let probe = GateProbe()
        let coord = makeGatedCoordinator(hosted: false, probe: probe)

        coord.attemptStart()

        #expect(probe.spawned == true)      // reached the spawn seam
        #expect(probe.reported == true)     // …and reported the freshly-bound --session-id
        #expect(coord.hasStarted == true)   // gate opened
    }
}
