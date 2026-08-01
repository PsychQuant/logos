import XCTest
import AppKit
import SwiftTerm
@testable import Logos

/// App-hosted XCTest (#102) — the `NSTextInputClient` marked-text (preedit)
/// contract the terminal must honor for multi-stage IMEs (bopomofo, pinyin,
/// kana-kanji, hangul) to work at all.
///
/// Hosted rather than in `swift test` for the same reason as
/// `RendererAdoptionTests`: a SwiftTerm `TerminalView` cannot be instantiated in
/// the bare `swift test` runner (it segfaults without an NSApplication /
/// windowserver drawable context — see `Sources/Logos/Terminal/SwiftTermView.swift`).
///
/// **This doubles as a fork-drift guard.** #102's root cause was not a missing
/// feature but a stale pin: `PsychQuant/SwiftTerm`'s `logos-renderer-base`
/// branched at `8e7a1e1` (2026-03-27), six days before upstream's
/// `c2fe63d` ("Fix macOS dictation and IME support in NSTextInputClient",
/// upstream #501) landed, and then sat 108 commits behind. Against the stale pin
/// these methods were hardcoded stubs (`hasMarkedText()` → `false`,
/// `markedRange()` → empty, `setMarkedText` discarding its argument), so the
/// input method was told "no composition in progress" and backspace fell through
/// `doCommand(by:)` to the PTY, deleting an already-committed character instead
/// of a composing keystroke. If a future fork update regresses past that commit,
/// these assertions fail loudly rather than silently returning CJK input to the
/// broken state.
@MainActor
final class MarkedTextContractTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    /// Builds a terminal view attached to a real window. The window matters:
    /// upstream's `setMarkedText` drives `updateMarkedTextOverlay()`, which reads
    /// the caret frame and adds a subview — both need a live view hierarchy.
    private func makeAttachedView(in window: NSWindow) -> TeedLocalProcessTerminalView {
        let view = TeedLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // Keep the GPU path out of this test: it is irrelevant to the text-input
        // contract, and the injectable seam avoids engaging a real Metal device.
        view.metalEnabler = { _ in }
        window.contentView = view
        window.orderFront(nil)
        return view
    }

    /// A composition in progress MUST be visible to AppKit through the client's
    /// own state, not merely accepted and dropped.
    ///
    /// These two assertions are the discriminating ones — against the pre-#501
    /// stub they fail on hardcoded return values regardless of what was composed.
    func test_setMarkedTextEstablishesCompositionState() {
        let window = makeWindow()
        defer { window.close() }
        let view = makeAttachedView(in: window)

        XCTAssertFalse(
            view.hasMarkedText(),
            "a freshly attached terminal reported a composition before any input"
        )

        // A single bopomofo consonant: the shape an IME hands over mid-composition.
        view.setMarkedText(
            "ㄅ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertTrue(
            view.hasMarkedText(),
            "hasMarkedText() stayed false after setMarkedText — the input method is being told there is no composition, so composition-editing keys (backspace) fall through to the PTY and delete committed text (#102)"
        )
        XCTAssertGreaterThan(
            view.markedRange().length, 0,
            "markedRange() reported an empty range while a composition was active — AppKit cannot locate the preedit (#102)"
        )
    }

    /// Committing or cancelling a composition MUST clear the state.
    ///
    /// NOTE: read this together with `test_setMarkedTextEstablishesCompositionState`.
    /// On its own this assertion passes against BOTH the stub (which returns
    /// `false` unconditionally) and a correct implementation, so it is not a
    /// drift guard by itself — it only earns its keep as the second half of a
    /// true state *transition*: set → marked, unmark → unmarked.
    func test_unmarkTextClearsCompositionState() {
        let window = makeWindow()
        defer { window.close() }
        let view = makeAttachedView(in: window)

        view.setMarkedText(
            "ㄅ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(view.hasMarkedText(), "precondition failed: no composition to unmark")

        view.unmarkText()

        XCTAssertFalse(
            view.hasMarkedText(),
            "hasMarkedText() stayed true after unmarkText — a finished composition would keep swallowing input"
        )
        XCTAssertEqual(
            view.markedRange().length, 0,
            "markedRange() still spanned a range after unmarkText"
        )
    }
}
