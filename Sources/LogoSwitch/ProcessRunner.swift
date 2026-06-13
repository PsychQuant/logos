import Foundation
import os

/// Injectable subprocess seam for LogoSwitch (#34). Deliberately **internal** — no
/// external consumer should get a generic "run any binary with any env" primitive;
/// the only callers are `ClaudeAuthInvoker` (fixed `["auth", …]` argv) and a binary
/// probe. Keeping it internal is part of the red-line defense: a `/usr/bin/security`
/// shell-out would be visible at a single, reviewable call site (and is caught by
/// RedLineAuditTests regardless).
struct ProcessRunner: Sendable {

    struct Result: Sendable {
        let exitCode: Int32
        let stdout: Data
        /// True iff the watchdog terminated the child at `timeout` (distinguished
        /// from a genuine non-zero exit so callers can't mislabel a hang).
        let timedOut: Bool
    }

    /// `(executable, args, env, timeout) -> Result`. `env == nil` inherits the
    /// parent environment.
    let run: @Sendable (_ executable: String, _ args: [String], _ env: [String: String]?, _ timeout: TimeInterval) -> Result

    /// Production runner. `stdin = /dev/null` (an interactive child gets EOF);
    /// `stderr = /dev/null` (never parsed — so there is no second pipe to wedge
    /// the stdout read, sidestepping the full-pipe deadlock entirely); `stdout`
    /// is drained to EOF on the calling thread BEFORE `waitUntilExit` (actively
    /// draining the single pipe can't deadlock). A watchdog terminates the child
    /// at `timeout`; the `timedOut` flag is lock-guarded (no unsynchronized
    /// cross-thread var).
    static let live = ProcessRunner { executable, args, env, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let env { process.environment = env }
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: Data(), timedOut: false)
        }

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.withLock { $0 = true }
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return Result(
            exitCode: process.terminationStatus,
            stdout: out,
            timedOut: timedOut.withLock { $0 }
        )
    }

    /// Test double: a deterministic `Result` from the args, no real subprocess.
    static func stub(_ handler: @escaping @Sendable (_ args: [String]) -> Result) -> ProcessRunner {
        ProcessRunner { _, args, _, _ in handler(args) }
    }
}
