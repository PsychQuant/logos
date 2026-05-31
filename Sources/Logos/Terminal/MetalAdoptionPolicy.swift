import Foundation
import os

/// Pure, view-independent decision for adopting the GPU Metal renderer
/// (renderer-c2-metal-adoption).
///
/// Extracted from `TeedLocalProcessTerminalView` so the enable / skip / once /
/// CoreGraphics-fallback logic is unit-testable: a SwiftTerm `TerminalView`
/// cannot be instantiated in a `swift test` process (it segfaults without a full
/// NSApplication / windowserver drawable context). The view-attachment glue and
/// real Metal engagement are therefore verified interactively (task 3.1), while
/// this policy carries the branching logic and is unit-tested directly.
@MainActor
struct MetalAdoptionPolicy {

    /// Whether an enable has already been attempted (so a repeated
    /// `viewDidMoveToWindow` does not re-attempt).
    private(set) var didAttempt = false

    /// Attempt to enable Metal exactly once, and only when the view is attached
    /// to a window (the renderer requires one). Returns `true` if `enable`
    /// succeeded; `false` if skipped (no window, or already attempted) or if
    /// `enable` threw — in which case the caller stays on the CoreGraphics path
    /// it used before, logged rather than surfaced (D4).
    @discardableResult
    mutating func attemptOnce(hasWindow: Bool, enable: () throws -> Void) -> Bool {
        guard hasWindow, !didAttempt else { return false }
        didAttempt = true
        do {
            try enable()
            return true
        } catch {
            // Error may carry filesystem paths from the renderer init — keep the
            // description default-redacted (#22 D3).
            Log.renderer.error("Metal renderer unavailable, staying on CoreGraphics: \(String(describing: error))")
            return false
        }
    }
}
