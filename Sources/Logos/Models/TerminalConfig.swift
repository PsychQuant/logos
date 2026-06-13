import Foundation
import Observation
import LogoSwitch

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

    /// Path to claude binary. Returns override if set; else searches the
    /// hydrated login-shell PATH (#33 — a Finder/Spotlight launch hands Logos
    /// the bare launchd PATH, which excludes ~/.local/bin / homebrew, so the
    /// old bare `which` failed with "claude CLI not found"); else falls back to
    /// the bare `which` (pre-#33 behavior); else nil (caller shows the
    /// ClaudeNotFoundBanner, and Settings → Advanced offers a manual override).
    public var resolvedClaudePath: String? {
        ClaudeBinaryResolver().resolve(
            override: claudePathOverride,
            path: LoginShellEnvironment.resolve()["PATH"]
        )
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
}
