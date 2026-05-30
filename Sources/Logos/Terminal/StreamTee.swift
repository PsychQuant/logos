import Foundation
import SwiftTerm

/// Subclass that taps bytes flowing from subprocess → terminal renderer.
/// Each chunk is forwarded to the parser/engine for auto-handle scanning,
/// then passed through to the normal renderer path.
///
/// **Adaptation note (vs. plan):** Plan suggested overriding
/// `feed(byteArray:)`. In SwiftTerm 1.13.0 that method is declared `public`
/// (not `open`) on `AppleTerminalView`, so we cannot override it. The
/// correct override slot is `dataReceived(slice:)` on
/// `LocalProcessTerminalView`, which is the `LocalProcessDelegate` entry
/// point that internally calls `feed(byteArray:)`. Tapping here gives us
/// every byte the renderer would have seen, before `feed()` runs.
@MainActor
public final class TeedLocalProcessTerminalView: LocalProcessTerminalView {

    /// Called for each byte chunk from the subprocess. Override point.
    public var onChunk: (([UInt8]) -> Void)?

    /// Called when the hosted subprocess terminates (PsychQuant/logos#18).
    /// Carries the exit code (nil if killed by a signal). Drives the
    /// Ghostty-faithful exit-state overlay — claude `/quit` should show an
    /// intentional state, never a frozen pane.
    public var onProcessTerminated: ((Int32?) -> Void)?

    /// Injectable Metal-enable action (test seam, renderer-c2-metal-adoption).
    /// Defaults to the SwiftTerm fork's real `setUseMetal(true)`. A test can
    /// substitute a throwing closure to exercise the CoreGraphics fallback (D4)
    /// without needing Metal-less hardware. Internal so `@testable` tests reach
    /// it; never set in production.
    var metalEnabler: (TeedLocalProcessTerminalView) throws -> Void = { try $0.setUseMetal(true) }

    /// Carries the enable/skip/once/fallback decision (renderer-c2-metal-adoption).
    /// The branching lives in `MetalAdoptionPolicy` (pure, unit-tested); this view
    /// only supplies window state and the enable action.
    private var metalPolicy = MetalAdoptionPolicy()

    public override func dataReceived(slice: ArraySlice<UInt8>) {
        // Byte tap runs BEFORE the renderer (CoreGraphics or Metal) sees the
        // bytes, so auto-handle is unaffected by which renderer is active.
        onChunk?(Array(slice))
        super.dataReceived(slice: slice)
    }

    /// Fired when the hosted subprocess exits. SwiftTerm delivers this on its
    /// dispatch queue (defaults to `DispatchQueue.main`, see SwiftTerm's
    /// `LocalProcess`), so it runs on the main actor here. We call `super` to
    /// preserve the fork's delegate-forward semantics, then notify our hook so
    /// the SwiftUI layer can show the exit-state overlay (#18).
    public override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        onProcessTerminated?(exitCode)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enableMetalIfAvailableOnce()
    }

    /// Adopt the fork's GPU Metal renderer once the view is window-attached,
    /// falling back to CoreGraphics if Metal is unavailable
    /// (renderer-c2-metal-adoption). Window-gating, the one-shot guard, and the
    /// fallback-on-throw live in `metalPolicy`; the enable action sets the per-row
    /// persistent buffering mode (the fork's Mac default, set explicitly to
    /// document intent) and calls the fork's `setUseMetal`.
    func enableMetalIfAvailableOnce() {
        // Escape hatch (audit discipline): Metal is a new default and could
        // misbehave on some hardware/sessions. `LOGOS_DISABLE_METAL` (any value)
        // forces the proven CoreGraphics path so a user is never locked out of a
        // working terminal. Consumes the one-shot attempt so we don't re-check.
        if ProcessInfo.processInfo.environment["LOGOS_DISABLE_METAL"] != nil {
            return
        }
        let engaged = metalPolicy.attemptOnce(hasWindow: window != nil) { [self] in
            metalBufferingMode = .perRowPersistent
            try metalEnabler(self)
        }
        if engaged {
            // Enabling Metal inserts an MTKView overlay and hides the native
            // caret (the Metal renderer draws its own, gated on the terminal being
            // first responder). Because we enable from viewDidMoveToWindow —
            // before AppKit/SwiftUI settle key focus — the terminal can end up not
            // first responder, so the Metal caret never renders and arrow-key
            // navigation has no target. Restore key focus to the terminal so
            // keyboard input and the caret work on the Metal path
            // (renderer-c2-metal-adoption, task 3.1 regression fix).
            window?.makeFirstResponder(self)
            // Diagnostic for interactive validation: confirms the GPU path
            // engaged rather than silently falling back to CoreGraphics.
            NSLog("Logos: terminal Metal renderer engaged")
        }
    }
}
