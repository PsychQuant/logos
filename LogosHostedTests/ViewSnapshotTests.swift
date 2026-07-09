import XCTest
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Logos
import LogoSwitch  // #39: AccountRow snapshots construct Account (a LogoSwitch type)

/// Visual-regression snapshots (#26) for stable, pure-input SwiftUI views.
/// App-hosted (TEST_HOST = Logos.app → window server) so the views actually
/// render — a bare `swift test` can't. Each view is hosted in an `NSHostingView`
/// at a pinned size with a forced light (`.aqua`) appearance for determinism.
///
/// Compare mode (no `record:` arg): the first run with no baseline records the
/// reference PNG **and fails** (the standard swift-snapshot-testing signal to
/// commit + re-run); committed runs compare → RED on a rendering change. Do NOT
/// hardcode `record: .all` here — that would silently re-record and never assert.
///
/// Cross-environment caveat (#26 Residue, softened #73): baselines are recorded
/// on a canonical machine. Comparison uses a perceptual tolerance (#73) — see
/// `snapshot()` — so a macOS point update's sub-visual anti-aliasing / font drift
/// no longer false-REDs. A different Retina scale or **system accent color** can
/// still exceed the tolerance: `.aqua` pins light/dark but NOT the accent, and
/// `AccountRow`'s active circle (`Color.accentColor`) + the overlay's
/// `.borderedProminent` buttons track `NSColor.controlAccentColor`, so a teammate
/// on a non-default accent may see a false RED. Pin size + appearance + tolerance
/// keep them stable within a consistent environment; treat them as a
/// canonical-environment guard, widened across OS point updates but not a full
/// cross-machine gate.
final class ViewSnapshotTests: XCTestCase {

    @MainActor
    private func snapshot(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        testName: String = #function
    ) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = NSAppearance(named: .aqua)  // force light, deterministic
        host.layoutSubtreeIfNeeded()
        // #73: perceptual tolerance, not raw-byte. `perceptualPrecision: 0.98`
        // routes swift-snapshot-testing off its `precision >= 1 && perceptualPrecision
        // >= 1` raw-byte short-circuit into `perceptuallyCompare`, where a pixel counts
        // as "different" only if its CIELAB Delta-E exceeds `(1 - 0.98) * 100 = 2` —
        // just above the ~1 ΔE just-noticeable-difference, so OS point-update AA/font
        // drift (well under ΔE 2) is absorbed. `precision: 0.98` must ALSO drop below 1
        // (not stay at 1.0): a few anti-aliased edge pixels can spike past ΔE 2, and
        // `precision` caps the fraction (≤2% of pixels) allowed to fully mismatch. Real
        // layout/color regressions perturb far more area and/or ΔE, so they still RED —
        // with one honest floor (#73 verify DA): a *small-area* content change (a short
        // word or comma-level edit in one text line of a large canvas, e.g. ~2,400px of
        // a 400×300 overlay) can fit inside the 2% budget and pass. The tolerance trades
        // that sliver of small-text sensitivity for OS-drift durability; see CLAUDE.md.
        assertSnapshot(
            of: host,
            as: .image(precision: 0.98, perceptualPrecision: 0.98),
            testName: testName
        )
    }

    @MainActor
    func test_terminalExitedOverlay_cleanExit() {
        snapshot(
            TerminalExitedOverlay(exitCode: 0, isAbnormal: false, onRestart: {}, onClose: {}),
            width: 400, height: 300
        )
    }

    @MainActor
    func test_terminalExitedOverlay_abnormal() {
        snapshot(
            TerminalExitedOverlay(exitCode: 137, isAbnormal: true, onRestart: {}, onClose: {}),
            width: 400, height: 300
        )
    }

    @MainActor
    func test_accountRow_active() {
        snapshot(
            AccountRow(
                account: Account(label: "work"),
                isActive: true,
                needsReauth: false,
                isEditing: false,
                onSelect: {},
                onBeginRename: {},
                onCommitRename: { _ in },
                onCancelRename: {},
                onDelete: {}
            ),
            width: 380, height: 44
        )
    }

    @MainActor
    func test_accountRow_needsReauth() {
        snapshot(
            AccountRow(
                account: Account(label: "personal"),
                isActive: false,
                needsReauth: true,
                isEditing: false,
                onSelect: {},
                onBeginRename: {},
                onCommitRename: { _ in },
                onCancelRename: {},
                onDelete: {}
            ),
            width: 380, height: 44
        )
    }

    // #60: the switcher's delete-failure caption (parity with the rename-error
    // affordance). Proves the `SheetErrorLine` renders; the end-to-end
    // failed-remove flow is Track-B (needs a persist-failure UI seam the harness
    // lacks — see #60).
    @MainActor
    func test_sheetErrorLine_delete() {
        snapshot(
            SheetErrorLine(
                // #69: mirrors delete()'s actual production message — keep in sync.
                message: "Couldn't remove the account — the change didn't save. Try again.",
                identifier: "logos.account.delete.error"
            ),
            width: 380, height: 40
        )
    }

    // #71: the add-account form's error state — pins the unified SheetErrorLine
    // integration (id logos.account.add.error, horizontalPadding 0 inside the
    // form's own 16pt inset). The VoiceOver announcement itself is non-visual;
    // this pins the layout half of #71.
    @MainActor
    func test_addAccountForm_error() {
        snapshot(
            AddAccountForm(
                label: .constant("work"),
                error: .constant("An account with that label already exists."),
                onSave: {},
                onCancel: {}
            ),
            width: 400, height: 240
        )
    }
}
