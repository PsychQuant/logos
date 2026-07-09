import XCTest
import SwiftUI
@testable import Logos

/// #75 option 3: proves the `announce` seam on `AccountSwitcherSheet` fires on
/// EVERY error-set, including a literal repeat of the same message — the case that
/// motivated #71 round 2. A repeated identical caption coalesces to a no-op render,
/// so the old `onAppear`/`onChange` hooks stayed silent; the imperative announce at
/// the mutation site does not. This asserts that behavior directly by injecting a
/// counting announcer (the seam's whole purpose) and driving the setters.
///
/// App-hosted because a bare `swift test` segfaults instantiating SwiftUI views
/// (#23/#26). Constructing the sheet here never evaluates its `body`, so the
/// `@Environment(AccountManager.self)` is never resolved — no AccountManager needed.
/// The setters' `@State` writes are undefined outside a render (SwiftUI logs a
/// warning and no-ops them); we assert only the announce side effect, not `@State`.
final class AnnouncerSeamTests: XCTestCase {

    private static let renameFailure =
        "Couldn't rename the account — the change didn't save. Try again."

    @MainActor
    func test_setError_announcesEveryTime_includingLiteralRepeat() {
        var announced: [String] = []
        let sheet = AccountSwitcherSheet(announce: { announced.append($0) })

        // Same message twice — the coalescing case the #71 round-2 design targets.
        sheet.setRenameError(Self.renameFailure)
        sheet.setRenameError(Self.renameFailure)

        XCTAssertEqual(
            announced,
            [Self.renameFailure, Self.renameFailure],
            "the literal-repeat announcement was swallowed — #71 round-2 regression"
        )
    }

    @MainActor
    func test_allFourSetters_routeThroughSeam() {
        var announced: [String] = []
        let sheet = AccountSwitcherSheet(announce: { announced.append($0) })

        sheet.setAddError("add")
        sheet.setRenameError("rename")
        sheet.setDeleteError("delete")
        sheet.setSystemDefaultError("systemDefault")

        XCTAssertEqual(
            announced,
            ["add", "rename", "delete", "systemDefault"],
            "a set*Error helper bypassed the announce seam"
        )
    }
}
