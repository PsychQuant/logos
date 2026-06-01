import XCTest
import Foundation

/// Shared harness for the Track B XCUITest flows.
///
/// `makeApp` is the reusable unblock from #24: `XCUIApplication().launch()` gives
/// the app a minimal environment whose PATH excludes claude, so the app's
/// `which claude` resolution fails → ClaudeNotFoundBanner → no terminal pane /
/// no spawn. Passing claude's path via the `--claude-path` test hook
/// (TerminalConfig honors it before `which`) makes claude spawn under XCUITest.
///
/// NOTE (#24 finding → #27): the XCUITest runner is sandboxed and CANNOT spawn
/// subprocesses — `pgrep` / `kill` / `log show` are all denied. So a flow cannot
/// drive claude to exit by killing its child, nor assert via the os.Logger trail.
/// Flows that need those must use a sandbox-compatible approach (a test-only
/// terminate affordance + pure-UI assertions) — tracked in #27.
@MainActor
enum UITestSupport {

    /// Build an XCUIApplication that can actually spawn claude (see type doc).
    static func makeApp(workspace: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        // `--ui-testing` gates the `--claude-path` hook (it's inert in production
        // without this co-flag) AND makes the passed claude path win over any
        // persisted Settings override on the dev machine. See TerminalConfig.
        var args: [String] = ["--ui-testing"]
        if let claude = resolveClaudePath() {
            args += ["--claude-path", claude]
        }
        if let workspace {
            args += ["--workspace", workspace]
        }
        app.launchArguments = args
        return app
    }

    /// Resolve the claude binary by checking common install locations. Uses
    /// `NSUserName()` (the real login name even when the UI-test runner is
    /// sandboxed) to build the home path — `NSHomeDirectory()` under the runner
    /// can resolve to a per-runner container, so `~/.local/bin/claude` would miss.
    static func resolveClaudePath() -> String? {
        let userHome = "/Users/\(NSUserName())"
        let candidates = [
            "\(userHome)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A unique non-system workspace dir with a marker file so the launch
    /// resolver accepts it and claude spawns.
    static func makeTempWorkspace(_ tag: String) -> String {
        let dir = NSTemporaryDirectory() + "logos-uitest-\(tag)-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/README.md", contents: Data("# uitest\n".utf8))
        return dir
    }
}
