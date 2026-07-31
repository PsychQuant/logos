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

        // spec 2026-07-31: the pane must reach a gateway DECISION before spawning.
        // Which decision depends on the account the smoke happens to launch with —
        // an isolated account acquires one, the system-default is deliberately
        // excluded — so accept either, and fail only on silence, which would mean
        // the gateway layer was skipped entirely.
        #expect(
            UnifiedLogReader.contains(launchEvents, category: "gateway-pool", message: "gateway acquired")
                || UnifiedLogReader.contains(launchEvents, category: "gateway-pool", message: "system-default account excluded")
                || UnifiedLogReader.contains(launchEvents, category: "gateway-pool", message: "no gateway command configured"),
            "no gateway-pool decision recorded — observed:\n\(Self.dump(launchEvents))"
        )

        // When a gateway WAS acquired, it must precede the spawn: a claude that
        // started first would have connected direct and never been paced.
        if let acquired = launchEvents.firstIndex(where: {
            $0.category == "gateway-pool" && $0.message.contains("gateway acquired")
        }), let spawned = launchEvents.firstIndex(where: {
            $0.category == "terminal" && $0.message.contains("spawned claude")
        }) {
            #expect(
                acquired < spawned,
                "gateway acquired AFTER claude spawned — observed:\n\(Self.dump(launchEvents))"
            )
        }

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
        // Match the claude EXECUTABLE, not any command line mentioning "claude".
        // Since the gateway layer (spec 2026-07-31) the app also spawns a proxy
        // child whose argv is
        // `python3 …/.claude/plugins/cache/claude-hot-limit/…/rate-limit-proxy.py`
        // — which contains "claude" twice. A bare `-f claude` filter killed THAT
        // instead, so the claude-exit assertion below never fired.
        guard let out = try? runCapturing("/usr/bin/pgrep", ["-P", logosPID, "-l", "-f", "claude"])
        else { return }

        // `pgrep -l` prints "<pid> <argv…>". Exclude the gateway rather than
        // requiring the executable to be named "claude": the real claude binary is
        // reached through a version symlink, so its resolved argv0 can be
        // `…/versions/2.1.220` with no "claude" basename at all.
        let claudePID = out
            .split(separator: "\n")
            .first { !$0.contains("rate-limit-proxy") }?
            .split(separator: " ").first
            .map(String.init)

        if let claudePID {
            _ = try? run("/bin/kill", [claudePID])
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
