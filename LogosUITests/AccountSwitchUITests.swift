import XCTest

/// #27 flow — account switch, sandbox-compatible + pure-UI.
///
/// Seeds two keychain-free stub accounts (`work` active, `personal` not), opens
/// the switcher from the status-bar account button, taps the non-active row, and
/// asserts the active-account **indicator moved** — the status-bar button renders
/// `mgr.active?.label`, so its label flipping `work` → `personal` is the positive
/// signal. The "no keychain dialog" negative stays the documented Residue (#12/#21):
/// XCUITest can't robustly prove a system dialog *didn't* appear, so this asserts
/// positives + app-alive only.
final class AccountSwitchUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testSwitchingActiveAccountMovesTheIndicator() throws {
        let ws = UITestSupport.makeTempWorkspace("switch")
        let app = UITestSupport.makeApp(workspace: ws, seedAccounts: ["work", "personal"])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app did not foreground")

        let accountButton = app.descendants(matching: .any)["logos.statusbar.accountButton"]
        guard accountButton.waitForExistence(timeout: 12) else {
            throw XCTSkip("status-bar account button not present in this launch state")
        }
        // Seeded order is work, personal → active = work → button shows "work".
        let labelBefore = accountButton.label
        XCTAssertTrue(labelBefore.contains("work"), "expected the seeded active account 'work' in the button label, got '\(labelBefore)'")

        accountButton.click()

        // AccountRow is `.onTapGesture` and all rows share one a11y id, so a
        // `boundBy:` index can hit a duplicate/ancestor match. Target the
        // non-active row by its label TEXT instead — the click lands inside the
        // row's `.contentShape(Rectangle())` → `onTapGesture` → setActive("personal").
        let personalRow = app.staticTexts["personal"]
        XCTAssertTrue(personalRow.waitForExistence(timeout: 5), "the 'personal' account row did not appear in the switcher")
        personalRow.click()

        let done = app.descendants(matching: .any)["logos.account.done"]
        if done.waitForExistence(timeout: 3) { done.click() }

        // Indicator moved: the status-bar button now reflects the new active account.
        let moved = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "personal"),
            evaluatedWith: accountButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [moved], timeout: 6), .completed,
            "active-account indicator did not move to 'personal' (button label stayed '\(accountButton.label)')"
        )
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during the account switch")
    }
}
