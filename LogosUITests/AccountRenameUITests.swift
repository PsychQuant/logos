import XCTest

/// #37 — double-click-to-rename, sandbox-compatible + pure-UI.
///
/// Two tests, split by whether they need keyboard text injection:
///
/// 1. `testDoubleClickRenamesWithoutSwitchingAccount` — the falsifiable answer to
///    the #36 6-AI verify's open GUI question: does a double-click ALSO fire the
///    row's single-tap select (switching + respawning the active account)? Needs
///    NO typing → CI-safe.
/// 2. `testRenameCommitUpdatesLabel` — the happy path (type a new name + Return →
///    label changes). `typeText` needs macOS to grant `testmanagerd` an input
///    method (a one-time prompt on a fresh machine; pre-provisioned in signed CI).
///    A UI-interruption monitor auto-allows the prompt; if keystrokes still don't
///    reach the field, the test `XCTSkip`s (distinguishing "input unavailable"
///    from "rename broken" via the field's own value, so a real bug is never hidden).
///
/// Mirrors `AccountSwitchUITests`: keychain-free seeded accounts, target rows by
/// label TEXT (all rows share one a11y id), positives + app-alive only.
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

        let personalRow = app.staticTexts["personal"]
        XCTAssertTrue(personalRow.waitForExistence(timeout: 5),
                      "the 'personal' account row did not appear in the switcher")

        personalRow.doubleClick()  // double-click the NON-active row → rename

        // (1) Rename mode entered — the inline TextField appears (label Text → TextField).
        let renameField = app.textFields["logos.account.rename.field"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5),
                      "double-click did not enter rename mode (no rename TextField appeared)")

        // (2) MUTUAL EXCLUSION (the #36 codex/devil's-advocate concern): the
        // double-click must NOT have also fired setActive. Active stays 'work'.
        XCTAssertTrue(accountButton.label.contains("work"),
                      "double-click ALSO switched the active account (button '\(accountButton.label)') — gesture mutual-exclusion failed")
        XCTAssertFalse(accountButton.label.contains("personal"),
                       "double-click switched active to 'personal' — it should only rename")
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

        let personalRow = app.staticTexts["personal"]
        XCTAssertTrue(personalRow.waitForExistence(timeout: 5), "the 'personal' row did not appear")
        personalRow.doubleClick()

        let renameField = app.textFields["logos.account.rename.field"]
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
        let renamed = app.staticTexts["home"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5),
                      "renamed row label 'home' did not appear after Return — rename did not commit")
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during the rename-commit flow")
    }
}
