import Testing
import Foundation

/// Headless smoke / E2E for the critical user flow (testing-smoke-e2e-strategy,
/// Task 2.2): launch the real bundled app, then assert the launch → workspace
/// load → claude spawn → process exit lifecycle by reading the os.Logger trail.
/// No pixels asserted — that is Track B (XCUITest). No real credentials needed:
/// claude may fail its own auth; spawn + exit still fire.
///
/// Gated behind `LOGOS_SMOKE=1` (set by `make smoke`) so a plain `swift test`
/// never launches the app. The `UnifiedLogReader` parse test in this same target
/// always runs; only this suite is env-gated.
@Suite(
    "Smoke",
    .enabled(if: ProcessInfo.processInfo.environment["LOGOS_SMOKE"] == "1")
)
struct SmokeTests {

    @Test("critical flow: launch → workspace load → claude spawn → exit are observable")
    func criticalFlowLifecycle() throws {
        let bundle = try Self.requireBundle()
        let workspace = try Self.makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let start = Date()
        try Self.launch(bundle: bundle, workspace: workspace)
        defer { Self.quit() }

        // Phase 1: launch + workspace + spawn should all appear within the window.
        let launchEvents = UnifiedLogReader.waitForEvents(since: start, timeout: 40) { e in
            UnifiedLogReader.contains(e, category: "app", message: "launch finished")
                && UnifiedLogReader.contains(e, category: "workspace", message: "workspace load succeeded")
                && UnifiedLogReader.contains(e, category: "terminal", message: "spawned claude")
        }

        #expect(
            UnifiedLogReader.contains(launchEvents, category: "app", message: "launch finished"),
            "no app launch-finished notice — observed:\n\(Self.dump(launchEvents))"
        )
        #expect(
            UnifiedLogReader.contains(launchEvents, category: "workspace", message: "workspace load succeeded"),
            "no workspace-load-success notice — observed:\n\(Self.dump(launchEvents))"
        )
        #expect(
            UnifiedLogReader.contains(launchEvents, category: "terminal", message: "spawned claude"),
            "no claude spawn notice — observed:\n\(Self.dump(launchEvents))"
        )

        // Phase 2: kill the hosted claude child while the app lives → the app's
        // PTY-termination path should log the exit (#18 / #22). This is the
        // exit half of the critical flow without needing the GUI Restart button
        // (restart's log emission is unit-covered by TerminalSessionStateTests;
        // the Restart UI control is Track B / XCUITest).
        Self.killClaudeChild()
        let exitEvents = UnifiedLogReader.waitForEvents(since: start, timeout: 20) { e in
            UnifiedLogReader.contains(e, category: "terminal", message: "claude process exited")
        }
        #expect(
            UnifiedLogReader.contains(exitEvents, category: "terminal", message: "claude process exited"),
            "no claude-exit notice after killing the child — observed:\n\(Self.dump(exitEvents))"
        )
    }

    // MARK: - Harness

    private static func requireBundle() throws -> String {
        let path = repoRoot()
            .appendingPathComponent(".build")
            .appendingPathComponent("Logos.app")
        let binary = path.appendingPathComponent("Contents/MacOS/Logos")
        try #require(
            FileManager.default.isExecutableFile(atPath: binary.path),
            "bundle missing at \(path.path) — run `make bundle` first (the `make smoke` target does this)"
        )
        return path.path
    }

    private static func makeTempWorkspace() throws -> String {
        // A unique non-system directory with a marker file so the launch
        // workspace resolver accepts it and the loader has something to walk.
        let dir = NSTemporaryDirectory() + "logos-smoke-ws-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/README.md", contents: Data("# smoke\n".utf8))
        return dir
    }

    private static func launch(bundle: String, workspace: String) throws {
        // `open` gives the app proper LaunchServices activation + a window-server
        // context (the terminal view only spawns claude once it is window-attached).
        try run("/usr/bin/open", [bundle, "--args", "--workspace", workspace])
    }

    private static func quit() {
        _ = try? run("/usr/bin/osascript", ["-e", "quit app \"Logos\""])
        _ = try? run("/usr/bin/pkill", ["-f", "Logos.app/Contents/MacOS/Logos"])
    }

    /// Kill the claude child of the running Logos app (PTY child), leaving the
    /// app alive so it can log the termination.
    private static func killClaudeChild() {
        guard let logosPID = firstPID(matching: "Logos.app/Contents/MacOS/Logos") else { return }
        // pgrep -P <logosPID> with the claude command filter.
        if let out = try? runCapturing("/usr/bin/pgrep", ["-P", logosPID, "-f", "claude"]),
           let childPID = out.split(separator: "\n").first.map(String.init) {
            _ = try? run("/bin/kill", [childPID])
        }
    }

    private static func firstPID(matching pattern: String) -> String? {
        guard let out = try? runCapturing("/usr/bin/pgrep", ["-f", pattern]) else { return nil }
        return out.split(separator: "\n").first.map(String.init)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func runCapturing(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dump(_ events: [UnifiedLogReader.Event]) -> String {
        events.map { "[\($0.category)] \($0.level): \($0.message)" }.joined(separator: "\n")
    }

    /// `#filePath` = <repo>/Tests/LogosSmokeTests/SmokeTests.swift
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LogosSmokeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
    }
}
