import XCTest
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Logos

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
/// Cross-environment caveat (#26 Residue): baselines are recorded on a canonical
/// machine; a different macOS version, Retina scale, or **system accent color**
/// may not byte-match at `precision: 1`. `.aqua` pins light/dark but NOT the
/// accent — `AccountRow`'s active circle (`Color.accentColor`) and the overlay's
/// `.borderedProminent` buttons track `NSColor.controlAccentColor`, so a teammate
/// on a non-default accent will see a false RED. Pin size + appearance keeps them
/// stable within a consistent environment; treat them as a single-canonical-env
/// guard, not a cross-machine gate.
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
        assertSnapshot(of: host, as: .image, testName: testName)
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
}
