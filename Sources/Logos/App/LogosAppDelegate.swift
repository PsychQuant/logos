import AppKit
import LogosGateway

/// Minimal delegate whose only job is orderly gateway teardown at quit.
///
/// A `Process` child is not reaped by the OS when its parent exits, so without
/// this every gateway spawned during the session would outlive the app and keep
/// holding its port. macOS has no equivalent of Linux's `PR_SET_PDEATHSIG`, so the
/// parent must clean up explicitly.
@MainActor
final class LogosAppDelegate: NSObject, NSApplicationDelegate {

    private var hasReplied = false

    /// Uses the async-terminate handshake rather than blocking in
    /// `applicationWillTerminate`: the teardown is actor work, and blocking the
    /// main thread on it while it awaits risks a deadlock.
    ///
    /// A watchdog bounds the handshake. `.terminateLater` means the app does not
    /// quit until `reply(toApplicationShouldTerminate:)` arrives, so a wedged child
    /// would otherwise make Logos un-quittable — and leave a half-dead instance that
    /// blocks the next launch. Losing a few seconds of orderly teardown is a far
    /// smaller failure than an app that will not close.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self.replyOnce()
            }
            await SharedGatewayPool.shared.shutdownAll()
            watchdog.cancel()
            self.replyOnce()
        }
        return .terminateLater
    }

    /// `reply(toApplicationShouldTerminate:)` is a one-shot handshake; the watchdog
    /// and the real teardown race to call it, so only the first may win.
    private func replyOnce() {
        guard !hasReplied else { return }
        hasReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
