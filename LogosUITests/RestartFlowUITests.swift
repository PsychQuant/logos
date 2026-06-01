import XCTest

/// #27 flow — the #18 Restart behavior, sandbox-compatible.
///
/// The XCUITest runner can't `kill` claude's child to drive exit (sandbox blocks
/// `Process`), so the exit is driven by the `--ui-testing`-gated terminate
/// affordance in `TerminalPaneView` (a click → `TerminalSessionState.markExited(0)`,
/// the same transition `StreamTee.processTerminated` drives). The flow then
/// asserts purely via UI: the exit overlay appears, Restart dismisses it.
///
/// Decision 1 (per the plan) resolved to the affordance, not type-to-stdin: a
/// keychain-free seeded account yields an *unauthenticated* claude (a login
/// prompt, not a `/quit`-able REPL), so typing `/quit` has no session to act on.
/// The affordance is deterministic regardless of claude's auth state.
final class RestartFlowUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testTerminateThenRestartShowsAndDismissesOverlay() throws {
        let ws = UITestSupport.makeTempWorkspace("restart")
        let app = UITestSupport.makeApp(workspace: ws, seedAccounts: ["work"])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app did not foreground")

        // The terminal pane only renders with an active account + a resolvable
        // claude path. The seed provides the account; claude must be installed on
        // this runner for the pane (hence the affordance) to exist.
        let terminate = app.descendants(matching: .any)["logos.terminal.uitestTerminate"]
        guard terminate.waitForExistence(timeout: 15) else {
            throw XCTSkip("terminal pane did not render — claude not resolvable on this runner (the exit flow needs a live terminal pane)")
        }

        // Drive the clean-exit overlay via the affordance (sandbox-compatible).
        terminate.click()
        let restart = app.descendants(matching: .any)["logos.terminal.restart"]
        XCTAssertTrue(
            restart.waitForExistence(timeout: 8),
            "exit overlay (logos.terminal.restart) did not appear after the terminate affordance"
        )

        // Restart → overlay dismisses (generation bump recreates a fresh session).
        restart.click()
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: restart)
        XCTAssertEqual(
            XCTWaiter.wait(for: [dismissed], timeout: 8), .completed,
            "exit overlay did not dismiss after clicking Restart"
        )
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during the restart flow")
    }
}
