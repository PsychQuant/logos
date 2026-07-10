import XCTest

/// #67 — the Track-B E2E for the failed-remove → delete-error-caption flow.
///
/// #60 made `AccountSwitcherSheet.delete()` surface a failed `remove()` instead of a
/// silent no-op, and #57 unit-tested the model rollback + a hosted snapshot pins the
/// caption's rendering. The hole was the MIDDLE — the live click → `remove()` fails →
/// `logos.account.delete.error` appears flow — because the `--ui-testing` harness had
/// no way to force a persist failure. `--seed-remove-fails` (#67) closes it: after
/// seeding, it chmods the volatile accounts-index dir read-only so the registry's
/// DESIGNED `.atomic`-write failure fires and `remove()` returns `false` for real.
///
/// One seeded account keeps the per-row trash button unambiguous. The trash button
/// is queried by its VoiceOver LABEL ("Delete account", #72) — its
/// `logos.account.delete` identifier (#67) is shadowed at runtime by the row
/// HStack's `logos.account.row` id (#24), which SwiftUI propagates onto every child
/// control (a pre-existing latent defect, unrelated to #72). Mirrors
/// `AccountRenameUITests` / `AccountSwitchUITests`: keychain-free seed, positives +
/// app-alive only, `XCTSkip` (never fail) if the launch state lacks the switcher.
///
/// Edit mode is entered via the `--ui-testing` `logos.account.beginRename` affordance
/// (targeted by its per-account label) — XCUITest cannot synthesize the count:2
/// double-click that drives rename for real users (see `AccountRenameUITests`' GESTURE
/// NOTE).
///
/// #68 scoping (binding): the delete-failure caption + row survival + no stacked
/// captions are HARD assertions; whether a delete-while-editing row STAYS in edit mode
/// is AppKit first-responder behavior — RECORDED as an observation, never asserted.
final class AccountDeleteFailureUITests: XCTestCase {

    /// The single seeded account label.
    private let seededLabel = "work"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launch with the persist-failure seam armed, open the switcher, and return the
    /// app. Skips (never fails) if the launch state lacks the switcher.
    @MainActor
    private func launchSwitcher(_ tag: String) throws -> XCUIApplication {
        let ws = UITestSupport.makeTempWorkspace(tag)
        let app = UITestSupport.makeApp(workspace: ws, seedAccounts: [seededLabel], seedRemoveFails: true)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app did not foreground")

        let accountButton = app.descendants(matching: .any)["logos.statusbar.accountButton"]
        guard accountButton.waitForExistence(timeout: 12) else {
            throw XCTSkip("status-bar account button not present in this launch state")
        }
        XCTAssertTrue(accountButton.label.contains(seededLabel),
                      "expected seeded active '\(seededLabel)', got '\(accountButton.label)'")
        accountButton.click()  // open the switcher sheet
        return app
    }

    /// Plain delete: a trash-click on a row whose registry persist FAILS must surface
    /// the failure caption (not a silent no-op) and leave the row alive.
    @MainActor
    func testDeleteFailureSurfacesCaptionAndRowSurvives() throws {
        let app = try launchSwitcher("delete-fail")

        let row = app.staticTexts[seededLabel]
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "the '\(seededLabel)' account row did not appear in the switcher")

        // Query by the VO label — the `logos.account.delete` id is shadowed by the
        // row id (see class doc). One seeded account → one "Delete account" button.
        let trash = app.buttons["Delete account"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "the trash button did not appear")
        trash.click()

        // HARD: the failure caption appears — assert on the IDENTIFIER, not the literal
        // string (the caption text is already duplicated in delete() + the hosted
        // snapshot; a third copy would rot).
        let caption = app.staticTexts["logos.account.delete.error"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5),
                      "a FAILED remove did not surface logos.account.delete.error — the tap looks like a silent no-op")
        // HARD: the row survives (remove() rolled back → the account is still alive).
        XCTAssertTrue(app.staticTexts[seededLabel].exists,
                      "the '\(seededLabel)' row vanished after a FAILED delete — the rollback did not keep it alive")
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during the delete-failure flow")
    }

    /// Delete-while-editing: begin a rename, then trash the SAME row. The trash-click
    /// synthesizes `AccountRow`'s focus-loss `cancelRename` in the same interaction; the
    /// #60 hardening means the delete-failure caption survives either ordering and the
    /// rename/delete captions never render stacked. Edit-mode retention is AppKit
    /// first-responder behavior (#68) → RECORDED as an observation, never asserted.
    @MainActor
    func testDeleteWhileEditingSurfacesCaptionWithoutStackedRenameError() throws {
        let app = try launchSwitcher("delete-editing")

        let row = app.staticTexts[seededLabel]
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "the '\(seededLabel)' account row did not appear in the switcher")

        // Enter inline-rename mode via the `--ui-testing` affordance (XCUITest cannot
        // synthesize AccountRow's count:2 double-click — see the class doc). This
        // drives the exact `onBeginRename` the real double-click drives.
        let beginRename = app.buttons["Begin rename \(seededLabel)"]
        XCTAssertTrue(beginRename.waitForExistence(timeout: 5),
                      "the begin-rename affordance for '\(seededLabel)' did not appear")
        beginRename.click()

        let renameField = app.textFields["Account name"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5),
                      "beginning rename did not enter rename mode (no rename TextField appeared)")

        // Query by the VO label — `logos.account.delete` is shadowed (see class doc).
        let trash = app.buttons["Delete account"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "the trash button did not appear while editing")
        trash.click()

        // HARD: the delete-failure caption appears — survives BOTH orderings of the
        // synthesized cancelRename by construction (cancelRename never clears
        // deleteError — the #60 round-2 fix).
        let deleteCaption = app.staticTexts["logos.account.delete.error"]
        XCTAssertTrue(deleteCaption.waitForExistence(timeout: 5),
                      "a FAILED delete-while-editing did not surface logos.account.delete.error")
        // HARD: the row survives — assert via the row CONTAINER id, which persists
        // whether or not the row stayed in edit mode (the label Text is hidden while the
        // TextField shows, so a label query would conflate survival with edit-mode).
        XCTAssertTrue(app.descendants(matching: .any)["logos.account.row"].exists,
                      "the row vanished after a FAILED delete-while-editing")
        // HARD: no STACKED captions — only deleteError shows, never a rename error too
        // (delete() clears renameError at entry — the #60 mutual-exclusivity invariant).
        XCTAssertFalse(app.staticTexts["logos.account.rename.error"].exists,
                       "a rename-error caption rendered STACKED with the delete-error caption")
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during the delete-while-editing flow")

        // OBSERVATION ONLY (#68 binding scope — NOT pass/fail): does the row stay in edit
        // mode after the trash-click? Whether the click resigns the TextField's first
        // responder (→ cancelRename → editingAccountId = nil → label reappears) is
        // AppKit-governed and deliberately unasserted. Record what THIS machine does so
        // the audit trail pins the real ordering; promote to a contract only once #68
        // decides the platform behavior is one.
        let stillEditing = app.textFields["Account name"].exists
        let labelBack = app.staticTexts[seededLabel].exists
        let observation = "delete-while-editing edit-mode retention — rename field present: \(stillEditing); label text present: \(labelBack)"
        NSLog("[#67 observation] %@", observation)
        XCTContext.runActivity(named: "OBSERVATION (#68, not asserted): \(observation)") { _ in }
    }
}
