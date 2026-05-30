import Testing
import Foundation
@testable import Logos

/// Tests for the terminal session lifecycle state (PsychQuant/logos#18).
/// `TerminalSessionState` drives the Ghostty-faithful exit-state overlay
/// (process exit shows an intentional state, never a frozen pane) and the
/// generation-based restart (bumping `generation` recreates the terminal view
/// → fresh claude spawn). Pure model — no GUI — so it is fully unit-tested.
@Suite("TerminalSessionState", .serialized)
@MainActor
struct TerminalSessionStateTests {

    @Test("starts in the running phase")
    func startsRunning() {
        let state = TerminalSessionState()
        #expect(state.phase == .running)
        #expect(state.hasExited == false)
        #expect(state.isAbnormal == false)
        #expect(state.generation == 0)
    }

    @Test("clean exit (code 0) is exited but not abnormal")
    func cleanExit() {
        let state = TerminalSessionState()
        state.markExited(0)
        #expect(state.phase == .exited(code: 0))
        #expect(state.hasExited == true)
        #expect(state.exitCode == 0)
        #expect(state.isAbnormal == false)
    }

    @Test("non-zero exit code is abnormal")
    func nonZeroExitIsAbnormal() {
        let state = TerminalSessionState()
        state.markExited(137)
        #expect(state.hasExited == true)
        #expect(state.exitCode == 137)
        #expect(state.isAbnormal == true)
    }

    @Test("nil exit code (signal / unknown) is abnormal")
    func nilExitIsAbnormal() {
        let state = TerminalSessionState()
        state.markExited(nil)
        #expect(state.hasExited == true)
        #expect(state.exitCode == nil)
        #expect(state.isAbnormal == true)
    }

    @Test("restart bumps generation and returns to running")
    func restartBumpsGeneration() {
        let state = TerminalSessionState()
        state.markExited(0)
        state.restart()
        #expect(state.generation == 1)
        #expect(state.phase == .running)
        #expect(state.hasExited == false)
        #expect(state.isAbnormal == false)
    }

    @Test("each restart increments generation monotonically")
    func restartIsMonotonic() {
        let state = TerminalSessionState()
        state.markExited(0)
        state.restart()
        state.markExited(1)
        state.restart()
        #expect(state.generation == 2)
        #expect(state.phase == .running)
    }
}
