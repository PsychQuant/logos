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
        // Test-support hook (#24): `--claude-path <path>` lets a UI test pass the
        // claude binary directly, bypassing the `which` PATH lookup. Needed because
        // `XCUIApplication().launch()` gives the app a minimal environment whose
        // PATH excludes claude, so `which` fails (an `open`-launched app inherits
        // the full login PATH and resolves fine). Non-persistent — mirrors the
        // `--workspace` launch arg; no effect unless the arg is present.
        if let argPath = Self.launchArgClaudePath() {
            return argPath
        }
        return Self.runWhich("claude")
    }

    /// Reads `--claude-path <path>` / `--claude-path=<path>` from launch args.
    static func launchArgClaudePath() -> String? {
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            if args[i] == "--claude-path", i + 1 < args.count {
                return args[i + 1]
            }
            if args[i].hasPrefix("--claude-path=") {
                return String(args[i].dropFirst("--claude-path=".count))
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
