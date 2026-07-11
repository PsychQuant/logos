import XCTest

/// #37 — inline account rename, sandbox-compatible + pure-UI.
///
/// GESTURE NOTE (Developer-Mode Track-B finding): XCUITest cannot synthesize the
/// SwiftUI `.onTapGesture(count: 2)` that triggers rename — element `.doubleClick()`,
/// raw window-coordinate `.doubleClick()`, an already-active-row double-click, and
/// two rapid `.click()`s were all measured, and none fire the count:2 recognizer (a
/// synthesized double-click is swallowed; two separate clicks fire single-tap
/// select twice). A GENUINE hardware double-click DOES enter rename and does NOT
/// switch the active account — verified out-of-band (real `cliclick` double-click,
/// screenshot-confirmed the inline field appeared with the active indicator
/// unmoved). So the #36 disambiguation is sound for real users; only the
/// XCUITest-synthesized path is un-drivable, and this is pre-existing (identical at
/// pre-#72). These tests therefore drive rename through the `--ui-testing`-gated
/// `logos.account.beginRename` affordance (same pattern as #27's terminate seam),
/// asserting the rename BEHAVIOR (edit-mode entry with no active-switch, then
/// commit) rather than re-synthesizing the un-drivable gesture.
///
/// Two tests, split by whether they need keyboard text injection:
///
/// 1. `testDoubleClickRenamesWithoutSwitchingAccount` — entering rename must not
///    ALSO switch the active account (the #36 6-AI verify's GUI concern). Driven via
///    the affordance; the gesture's own mutual-exclusion is the out-of-band finding
///    above. Needs NO typing → CI-safe.
/// 2. `testRenameCommitUpdatesLabel` — the happy path (type a new name + Return →
///    label changes). `typeText` needs macOS to grant `testmanagerd` an input
///    method (a one-time prompt on a fresh machine; pre-provisioned in signed CI).
///    A UI-interruption monitor auto-allows the prompt; if keystrokes still don't
///    reach the field, the test `XCTSkip`s (distinguishing "input unavailable"
///    from "rename broken" via the field's own value, so a real bug is never hidden).
///
/// Mirrors `AccountSwitchUITests`: keychain-free seeded accounts, target the rename
/// affordance by its per-account VoiceOver label, positives + app-alive only.
final class AccountRenameUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Open the switcher seeded with work(active)/personal and return the app +
    /// status-bar account button (asserts the seeded active is "work").
    @MainActor
    private func launchSwitcher(_ tag: String) throws -> (XCUIApplication, XCUIElement) {
        let ws = UITestSupport.makeTempWorkspace(tag)
        let app = UITestSupport.makeApp(workspace: ws, seedAccounts: ["work", "personal"])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app did not foreground")

        let accountButton = app.descendants(matching: .any)["logos.statusbar.accountButton"]
        guard accountButton.waitForExistence(timeout: 12) else {
            throw XCTSkip("status-bar account button not present in this launch state")
        }
        XCTAssertTrue(accountButton.label.contains("work"),
                      "expected seeded active 'work', got '\(accountButton.label)'")
        accountButton.click()  // open the switcher sheet
        return (app, accountButton)
    }

    /// The crux of #37 — no typing, so this runs anywhere Track B runs.
    @MainActor
    func testDoubleClickRenamesWithoutSwitchingAccount() throws {
        let (app, accountButton) = try launchSwitcher("rename-mx")

        // The account-label element carries `.isButton` (#77) → query it as a button.
        let personalRow = app.buttons["personal"]
        XCTAssertTrue(personalRow.waitForExistence(timeout: 5),
                      "the 'personal' account row did not appear in the switcher")

        // Enter rename via the `--ui-testing` affordance (XCUITest cannot synthesize
        // the count:2 double-click — see the GESTURE NOTE on this class). The
        // affordance calls the exact `onBeginRename` the real double-click drives.
        let beginRename = app.buttons["Begin rename personal"]
        XCTAssertTrue(beginRename.waitForExistence(timeout: 5),
                      "the begin-rename affordance for 'personal' did not appear")
        beginRename.click()

        // (1) Rename mode entered — the inline TextField appears (label Text → TextField).
        let renameField = app.textFields["Account name"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5),
                      "beginning rename did not enter rename mode (no rename TextField appeared)")

        // (2) MUTUAL EXCLUSION (the #36 codex/devil's-advocate concern): beginning
        // a rename must NOT fire setActive. Active stays 'work'. (The GESTURE's own
        // mutual-exclusion — a real double-click not switching — is the out-of-band
        // finding in the GESTURE NOTE; here we assert the `onBeginRename` path itself
        // never switches, which the affordance drives identically to the gesture.)
        XCTAssertTrue(accountButton.label.contains("work"),
                      "beginning rename ALSO switched the active account (button '\(accountButton.label)')")
        XCTAssertFalse(accountButton.label.contains("personal"),
                       "beginning rename switched active to 'personal' — it should only rename")
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during the rename-enter flow")
    }

    /// Happy path — needs keyboard input (see class doc on the testmanagerd grant).
    @MainActor
    func testRenameCommitUpdatesLabel() throws {
        // Auto-allow the one-time "testmanagerd input method" system prompt that
        // `typeText` triggers on a fresh machine.
        addUIInterruptionMonitor(withDescription: "input-method permission") { element in
            for label in ["允許", "Allow"] {
                let button = element.buttons[label]
                if button.exists { button.click(); return true }
            }
            return false
        }

        let (app, _) = try launchSwitcher("rename-commit")

        // The account-label element carries `.isButton` (#77) → query it as a button.
        let personalRow = app.buttons["personal"]
        XCTAssertTrue(personalRow.waitForExistence(timeout: 5), "the 'personal' row did not appear")

        // Enter rename via the `--ui-testing` affordance (see the GESTURE NOTE).
        let beginRename = app.buttons["Begin rename personal"]
        XCTAssertTrue(beginRename.waitForExistence(timeout: 5),
                      "the begin-rename affordance for 'personal' did not appear")
        beginRename.click()

        let renameField = app.textFields["Account name"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5), "no rename TextField appeared")

        renameField.click()                                 // focus + trigger the interruption monitor
        app.typeText("")                                    // nudge the monitor if the dialog is up
        renameField.typeKey("a", modifierFlags: .command)   // select-all the seeded "personal"
        renameField.typeText("home")

        // Did the keystrokes reach the field? If not, the input-method grant is
        // missing (and unattended) — skip rather than hide a real rename bug.
        let fieldValue = (renameField.value as? String) ?? ""
        guard fieldValue.contains("home") else {
            throw XCTSkip("text input did not reach the field (testmanagerd input-method permission not granted) — run locally after allowing, or pre-grant in CI. Field value: '\(fieldValue)'")
        }

        // Keystrokes landed → assert the rename actually commits (hard).
        renameField.typeKey(.enter, modifierFlags: [])
        // Post-commit the label Text re-renders (with `.isButton`, #77) → query as a button.
        let renamed = app.buttons["home"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5),
                      "renamed row label 'home' did not appear after Return — rename did not commit")
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during the rename-commit flow")
    }
}
