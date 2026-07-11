import Foundation
import SwiftTerm
import os

/// #78 detection seam: is this host process running in-process XCTest unit
/// tests (the `LogosHostedTests` bundle)? An app-hosted `bundle.unit-test`
/// injects its bundle into a fully-launching `Logos.app`, whose production UI
/// asynchronously spawns the real `--dangerously-skip-permissions` claude child
/// AND engages the GPU Metal renderer (`setUseMetal(true)`) ~2s in — landing on
/// whichever bystander test is executing then (RendererAdoptionTests) as an
/// "unexpected exit," and leaving a live privileged process inside
/// `xcodebuild test`. XCTest sets `XCTestConfigurationFilePath` in the host
/// process env for that bundle type ONLY; the XCUITest runner (LogosUITests)
/// launches `Logos.app` as a SEPARATE, clean process that self-identifies via
/// the `--ui-testing` argument and carries no such env var — so this probe
/// leaves the XCUITest terminal, which legitimately renders + spawns, untouched
/// (the two signals are orthogonal: one env var, one launch argument). Pure and
/// env-injectable so a unit test can assert both branches without mutating the
/// ambient process environment.
enum HostedTestEnvironment {
    static func isHostedUnitTesting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}

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

    /// #78: set true by the production `SwiftTermView.makeNSView` creation site
    /// when the host process is running in-process unit tests (see
    /// `HostedTestEnvironment`), so a production terminal view brought up by the
    /// app UI inside an app-hosted `xcodebuild test` skips the real GPU Metal
    /// engagement below. Defaults false so a directly-constructed test view
    /// (RendererAdoptionTests) — which supplies its own `metalEnabler` and MUST
    /// still exercise the adoption path in that same hosted process — is never
    /// gated. Mirrors the `metalEnabler` seam: a safe default, set at the
    /// production creation site, so the injection distinguishes production views
    /// from directly-constructed test views (both live in one process, one env).
    var isHostedUnitTesting = false

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
        //
        // #78: also short-circuit when a production view is brought up inside a
        // host process running in-process unit tests — the real `setUseMetal(true)`
        // engagement is a bystander crasher there. `isHostedUnitTesting` is set by
        // the production `makeNSView` seam only, so a directly-constructed test
        // view (RendererAdoptionTests) stays false and still drives this path.
        if ProcessInfo.processInfo.environment["LOGOS_DISABLE_METAL"] != nil
            || isHostedUnitTesting {
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
            Log.renderer.notice("terminal Metal renderer engaged")
        }
    }
}
