import XCTest
import AppKit
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
    }

    /// When the enabler throws (Metal unavailable), the view swallows it (logs
    /// `.error`) and stays on CoreGraphics — no crash, no rethrow, view alive.
    func test_coreGraphicsFallbackWhenEnablerThrows() {
        struct SimulatedNoMetalDevice: Error {}
        let view = TeedLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.metalEnabler = { _ in throw SimulatedNoMetalDevice() }

        let window = makeWindow()
        defer { window.close() }
        window.contentView = view
        window.orderFront(nil)

        // Reaching here without a crash/rethrow IS the contract; confirm the view
        // is still attached and usable.
        XCTAssertNotNil(view.window, "view was torn down by the fallback path")
    }

    /// The `LOGOS_DISABLE_METAL` escape hatch: when set, the view skips the Metal
    /// attempt entirely even with a window present.
    func test_disableMetalEnvSkipsAttempt() {
        setenv("LOGOS_DISABLE_METAL", "1", 1)
        defer { unsetenv("LOGOS_DISABLE_METAL") }

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
