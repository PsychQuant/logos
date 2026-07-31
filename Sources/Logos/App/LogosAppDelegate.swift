import AppKit
import LogosGateway

/// Minimal delegate whose only job is orderly gateway teardown at quit.
///
/// A `Process` child is not reaped by the OS when its parent exits, so without
/// this every gateway spawned during the session would outlive the app and keep
/// holding its port. macOS has no equivalent of Linux's `PR_SET_PDEATHSIG`, so
/// the parent must clean up explicitly.
final class LogosAppDelegate: NSObject, NSApplicationDelegate {

    /// Uses the async-terminate handshake rather than blocking in
    /// `applicationWillTerminate`: the teardown is actor work, and blocking the
    /// main thread on it while it awaits risks a deadlock. `.terminateLater` lets
    /// the shutdown run to completion and then resumes the quit.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        Task {
            await SharedGatewayPool.shared.shutdownAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
