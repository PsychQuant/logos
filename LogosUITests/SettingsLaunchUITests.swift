import XCTest

/// Track B UI end-to-end (testing-smoke-e2e-strategy, Task 3.2).
///
/// The regression contract for PsychQuant/logos#20: opening the Settings scene
/// used to trap (`EnvironmentValues.subscript.getter` assertionFailure → SIGTRAP)
/// because the `Settings` scene did not inherit the WindowGroup's `.environment`.
/// A log-trail smoke (Track A) catches a crash only as "process died"; this UI
/// test asserts the pixel-level contract a log cannot prove — Settings opens,
/// shows a window, and the app stays alive.
final class SettingsLaunchUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testOpeningSettingsDoesNotCrashAndShowsWindow() {
        let app = XCUIApplication()
        // Launch into the welcome state — no workspace arg, so no claude spawn is
        // required for this UI assertion.
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "app did not reach the foreground after launch"
        )

        let windowsBefore = app.windows.count

        // Standard macOS "open Settings" shortcut.
        app.typeKey(",", modifierFlags: .command)

        // Wait for a new window (the Settings window) to appear.
        let settingsAppeared = NSPredicate(format: "count > %d", windowsBefore)
        let exp = expectation(for: settingsAppeared, evaluatedWith: app.windows)
        let windowResult = XCTWaiter.wait(for: [exp], timeout: 8)

        // #20 core contract: the app MUST NOT crash on opening Settings (the bug
        // was a SIGTRAP on open). A crash shows as `.notRunning`; under XCUITest
        // the app is legitimately backgrounded (the runner is foreground), so any
        // running state (background/suspended/foreground) satisfies "did not crash".
        XCTAssertNotEqual(
            app.state, .notRunning,
            "app crashed (.notRunning) after opening Settings — the #20 regression"
        )
        XCTAssertEqual(
            windowResult, .completed,
            "no Settings window appeared after Cmd+, (windows stayed at \(windowsBefore))"
        )
    }
}
