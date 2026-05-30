import Foundation
import Observation

/// Observable lifecycle state for the hosted claude session in a terminal pane
/// (PsychQuant/logos#18). Drives the Ghostty-faithful exit-state overlay — when
/// the hosted process exits, the pane shows an intentional state with restart /
/// close rather than freezing — and the generation-based restart: bumping
/// `generation` changes the SwiftUI view identity so the terminal view is
/// recreated, spawning a fresh claude with a fresh detector/parser and
/// re-materialized per-account credentials (#12 / #17 survive restart).
///
/// **Scope boundary**: this models CLEAN process exit (user `/quit` / `/exit`).
/// A future crash auto-recovery watchdog must distinguish abnormal termination
/// via `isAbnormal` so clean-exit (this overlay) and crash-restart never collide.
@Observable
@MainActor
public final class TerminalSessionState {

    public enum Phase: Equatable {
        case running
        case exited(code: Int32?)
    }

    public private(set) var phase: Phase = .running

    /// Incremented by `restart()`. Callers fold this into the terminal view's
    /// SwiftUI `.id` so a bump forces a fresh spawn.
    public private(set) var generation: Int = 0

    public init() {}

    /// True once the hosted process has terminated (overlay should show).
    public var hasExited: Bool {
        if case .exited = phase { return true }
        return false
    }

    /// The process exit code, or nil if exited without one (e.g. killed by a
    /// signal). nil only when `hasExited`.
    public var exitCode: Int32? {
        if case let .exited(code) = phase { return code }
        return nil
    }

    /// Ghostty-style clean/abnormal distinction: a nil (signal / unknown) or
    /// non-zero exit code is abnormal. False while running.
    public var isAbnormal: Bool {
        guard case let .exited(code) = phase else { return false }
        guard let code else { return true }
        return code != 0
    }

    /// Record that the hosted process terminated with the given exit code.
    public func markExited(_ code: Int32?) {
        phase = .exited(code: code)
    }

    /// Restart the session: bump `generation` (recreates the terminal view →
    /// fresh spawn) and return to the running phase.
    public func restart() {
        generation += 1
        phase = .running
    }
}
