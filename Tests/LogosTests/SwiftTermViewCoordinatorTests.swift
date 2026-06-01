import Testing
import Foundation
@testable import Logos

/// End-to-end-at-the-Coordinator-seam tests for the passive re-auth banner
/// wiring (PsychQuant/logos#30 Item 3). The pure unit tests prove the detector +
/// state in isolation; these drive the live `handleChunk` path: a 401 emitted by
/// the hosted process flips `TerminalSessionState.needsAuth`, AND it still does
/// so when the signal is split across chunks with an auto-handle `parser.reset()`
/// interleaved — the exact regression #30 Item 1 fixes.
@Suite("SwiftTermView.Coordinator", .serialized)
@MainActor
final class SwiftTermViewCoordinatorTests {

    // Release the isolated UserDefaults suites the AccountManager doubles use (#16).
    private let tracker = IsolatedDefaultsTracker()
    deinit { tracker.teardown() }

    private func makeCoordinator(engine: AutoHandleEngine) -> SwiftTermView.Coordinator {
        let config = ClaudeProcessConfig(executablePath: "/bin/echo")
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: InMemorySystemKeychainBridge(),
            defaults: tracker.make(prefix: "LogosCoord")
        )
        return SwiftTermView.Coordinator(
            processConfig: config,
            engine: engine,
            accountManager: mgr,
            sessionState: TerminalSessionState()
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
}
