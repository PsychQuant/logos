import XCTest
import AppKit
import SwiftTerm
@testable import Logos

/// App-hosted XCTest (#23) — runs in-process with an NSApplication + window
/// server (TEST_HOST = Logos.app), so it can instantiate the SwiftTerm view that
/// segfaults in the bare `swift test` runner. Covers the **view→policy wiring**
/// the pure `MetalAdoptionPolicy` tests (Tests/LogosTests/SwiftTermViewMetalTests)
/// cannot reach: `viewDidMoveToWindow` → `enableMetalIfAvailableOnce`, gated on a
/// real window. Asserts via the injectable `metalEnabler` seam (deterministic, no
/// real GPU); real Metal engagement stays the interactive/smoke path.
@MainActor
final class RendererAdoptionTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    /// Attaching the view to a real window drives the Metal adoption path:
    /// `viewDidMoveToWindow` → `enableMetalIfAvailableOnce` (window present) →
    /// the policy invokes the injected enabler with the view itself.
    func test_metalEngagesWhenWindowAttached() {
        let view = TeedLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var capturedView: TeedLocalProcessTerminalView?
        view.metalEnabler = { capturedView = $0 }

        let window = makeWindow()
        defer { window.close() }
        window.contentView = view   // synchronous viewDidMoveToWindow
        window.orderFront(nil)

        XCTAssertNotNil(
            capturedView,
            "viewDidMoveToWindow did not drive the Metal adoption path on window attach"
        )
        XCTAssertTrue(capturedView === view, "the adoption path passed the wrong view to the enabler")
        // Teeth (verify #23): the enable closure sets the per-row persistent
        // buffering mode BEFORE calling the enabler. Asserting it directly guards
        // against a production regression that drops the buffering side-effect
        // (which the capturing-enabler signal alone would not catch).
        XCTAssertEqual(
            view.metalBufferingMode, .perRowPersistent,
            "the adoption path did not set per-row persistent buffering before enabling"
        )
    }

    /// When the enabler throws (Metal unavailable), the view swallows it (logs
    /// `.error`) and stays on CoreGraphics — no crash, no rethrow, view alive.
    func test_coreGraphicsFallbackWhenEnablerThrows() {
        struct SimulatedNoMetalDevice: Error {}
        let view = TeedLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var enablerInvoked = false
        view.metalEnabler = { _ in
            enablerInvoked = true
            throw SimulatedNoMetalDevice()
        }

        let window = makeWindow()
        defer { window.close() }
        window.contentView = view
        window.orderFront(nil)

        // Teeth (verify #23): assert the catch branch was actually exercised —
        // the enabler was reached and threw (NOT skipped by an inverted
        // window-gate or a misfiring env-gate, which a bare window!=nil check
        // would let pass), and the view swallowed it (no crash/rethrow) and
        // stayed attached on the CoreGraphics path.
        XCTAssertTrue(enablerInvoked, "fallback path never invoked the enabler — the catch branch was not exercised")
        XCTAssertNotNil(view.window, "view was torn down by the fallback path")
    }

    /// The `LOGOS_DISABLE_METAL` escape hatch: when set, the view skips the Metal
    /// attempt entirely even with a window present.
    func test_disableMetalEnvSkipsAttempt() {
        // Save + restore the original value (verify #23): a bare unsetenv would
        // wipe the variable if the surrounding environment had it set.
        let key = "LOGOS_DISABLE_METAL"
        let original = ProcessInfo.processInfo.environment[key]
        setenv(key, "1", 1)
        defer {
            if let original { setenv(key, original, 1) } else { unsetenv(key) }
        }

        let view = TeedLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var enablerInvoked = false
        view.metalEnabler = { _ in enablerInvoked = true }

        let window = makeWindow()
        defer { window.close() }
        window.contentView = view
        window.orderFront(nil)

        XCTAssertFalse(enablerInvoked, "LOGOS_DISABLE_METAL should have skipped the Metal attempt")
    }
}
