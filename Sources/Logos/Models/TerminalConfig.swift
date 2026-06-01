import Foundation
import Observation

@Observable
@MainActor
public final class TerminalConfig {

    public var fontName: String = "Menlo"
    public var fontSize: CGFloat = 13
    public var backgroundColorHex: String = "#1e1e1e"
    public var foregroundColorHex: String = "#d4d4d4"

    /// Optional override. If nil, resolves via `which claude`.
    @ObservationIgnored public let claudePathOverride: String?

    public init(claudePathOverride: String? = nil) {
        self.claudePathOverride = claudePathOverride
    }

    /// Path to claude binary. Returns override if set, else `which claude` result,
    /// else nil (caller should show "claude not found" error).
    public var resolvedClaudePath: String? {
        if let override = claudePathOverride {
            return override
        }
        return Self.runWhich("claude")
    }

    /// The claude binary path passed by a UI test (#24), honored ONLY when
    /// `--ui-testing` is also present — so the hook has ZERO surface in a normal
    /// production launch (no ungated arbitrary-binary launch arg). Callers prefer
    /// this over the persisted `claudePathOverride` during a UI test (see
    /// `TerminalPaneView`), so the test's claude wins even on a dev machine that
    /// has a Settings override set (which would otherwise shadow it).
    ///
    /// Why the hook exists: `XCUIApplication().launch()` gives the app a minimal
    /// environment whose PATH excludes claude, so the `which` lookup fails →
    /// ClaudeNotFoundBanner → no spawn (an `open`-launched app inherits the full
    /// login PATH and resolves fine).
    static func uiTestingClaudePath() -> String? {
        guard CommandLine.arguments.contains("--ui-testing") else { return nil }
        return launchArgClaudePath()
    }

    /// Reads `--claude-path` from the process launch args. Delegates to the pure
    /// `parseClaudePathArg(from:)` (unit-tested) so the real entry point stays a
    /// one-liner over `CommandLine.arguments`.
    static func launchArgClaudePath() -> String? {
        parseClaudePathArg(from: CommandLine.arguments)
    }

    /// Pure parser for `--claude-path <path>` / `--claude-path=<path>`. Returns nil
    /// for an empty value, or when the space-form's next token is itself an option
    /// (e.g. `--claude-path --workspace ...`). Injectable for unit tests.
    static func parseClaudePathArg(from args: [String]) -> String? {
        var i = 1
        while i < args.count {
            if args[i] == "--claude-path", i + 1 < args.count {
                let value = args[i + 1]
                return (value.isEmpty || value.hasPrefix("--")) ? nil : value
            }
            if args[i].hasPrefix("--claude-path=") {
                let value = String(args[i].dropFirst("--claude-path=".count))
                return value.isEmpty ? nil : value
            }
            i += 1
        }
        return nil
    }

    private static func runWhich(_ binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binary]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }
}
