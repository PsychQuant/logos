import XCTest

/// #27 flow — the dangerous-mode toggle (#19), the lowest-risk of the three
/// behavior flows: no terminal driving, no account, pure Settings UI. argv
/// propagation of `--dangerously-skip-permissions` is already covered by #22's
/// spawn `.notice` (Track A smoke) + unit tests, so this asserts only the
/// toggle's UI behavior + within-session persistence.
final class DangerousToggleUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Resolve the dangerous-mode toggle across the element types a SwiftUI
    /// `Toggle` can surface as on macOS (checkbox / switch / generic descendant).
    @MainActor
    private func dangerToggle(in app: XCUIApplication) -> XCUIElement {
        let id = "logos.settings.dangerousToggle"
        let checkbox = app.checkBoxes[id]
        if checkbox.exists { return checkbox }
        let sw = app.switches[id]
        if sw.exists { return sw }
        return app.descendants(matching: .any)[id]
    }

    @MainActor
    func testDangerousToggleFlipsAndHolds() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app did not foreground")

        // Open Settings (⌘,) and switch to the Advanced tab.
        app.typeKey(",", modifierFlags: .command)
        let advancedTab = app.toolbars.buttons["Advanced"]
        XCTAssertTrue(advancedTab.waitForExistence(timeout: 8), "Advanced settings tab did not appear")
        advancedTab.click()

        let toggle = dangerToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "dangerous-mode toggle not found on the Advanced tab")

        // Flip it and assert the UI state changed (checkbox value is "0"/"1").
        let before = toggle.value as? String
        toggle.click()
        let flippedPredicate = NSPredicate(format: "value != %@", before ?? "")
        let exp = expectation(for: flippedPredicate, evaluatedWith: toggle)
        XCTAssertEqual(
            XCTWaiter.wait(for: [exp], timeout: 4), .completed,
            "toggle did not flip after click (stayed \(before ?? "nil"))"
        )

        // Within-session persistence: flip back, confirm it tracks again.
        let after = toggle.value as? String
        toggle.click()
        let restoredPredicate = NSPredicate(format: "value != %@", after ?? "")
        let exp2 = expectation(for: restoredPredicate, evaluatedWith: toggle)
        XCTAssertEqual(
            XCTWaiter.wait(for: [exp2], timeout: 4), .completed,
            "toggle did not track the second click"
        )
        XCTAssertNotEqual(app.state, .notRunning, "app crashed while toggling")
    }
}
