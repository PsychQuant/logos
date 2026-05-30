import Testing
import Foundation
@testable import Logos

/// Tests for the C.2 Metal-renderer adoption decision logic
/// (renderer-c2-metal-adoption).
///
/// These exercise `MetalAdoptionPolicy` — the pure enable/skip/once/fallback
/// branching extracted from `TeedLocalProcessTerminalView`. The view itself is
/// NOT instantiated here: creating a SwiftTerm `TerminalView` (or attaching it
/// to a window) in a `swift test` process segfaults (no full NSApplication /
/// windowserver drawable context). Real Metal engagement
/// (`isUsingMetalRenderer == true`), the byte tap on the live Metal path, and
/// caret/selection/resize are therefore verified INTERACTIVELY on the running
/// app (task 3.1); this suite covers the logic that decides whether and when to
/// enable.
@Suite("MetalAdoptionPolicy", .serialized)
@MainActor
struct MetalAdoptionPolicyTests {

    // MARK: - 1.1 Terminal enables the Metal renderer when available

    @Test("attempts the enable when the view has a window")
    func attemptsWhenWindowed() {
        var policy = MetalAdoptionPolicy()
        var enabled = false
        let result = policy.attemptOnce(hasWindow: true) { enabled = true }
        #expect(enabled == true)
        #expect(result == true)
        #expect(policy.didAttempt == true)
    }

    @Test("does not attempt the enable before the view has a window")
    func skipsWhenNoWindow() {
        var policy = MetalAdoptionPolicy()
        var enabled = false
        let result = policy.attemptOnce(hasWindow: false) { enabled = true }
        #expect(enabled == false)
        #expect(result == false)
        #expect(policy.didAttempt == false)  // a later window-attach can still try
    }

    // MARK: - 1.2 Terminal falls back to CoreGraphics when Metal is unavailable

    @Test("falls back (returns false, does not rethrow) when the enable throws")
    func fallsBackWhenEnableThrows() {
        struct SimulatedNoMetalDevice: Error {}
        var policy = MetalAdoptionPolicy()
        let result = policy.attemptOnce(hasWindow: true) { throw SimulatedNoMetalDevice() }
        #expect(result == false)            // stayed on CoreGraphics
        #expect(policy.didAttempt == true)  // attempt consumed — no thrash-retry loop
    }

    @Test("attempts the enable at most once across repeated window moves")
    func attemptsAtMostOnce() {
        var policy = MetalAdoptionPolicy()
        var count = 0
        _ = policy.attemptOnce(hasWindow: true) { count += 1 }
        let second = policy.attemptOnce(hasWindow: true) { count += 1 }
        #expect(count == 1)
        #expect(second == false)
    }
}
