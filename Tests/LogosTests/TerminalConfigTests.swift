import Testing
@testable import Logos

@Suite("TerminalConfig", .serialized)
@MainActor
struct TerminalConfigTests {

    @Test("default font is Menlo 13pt")
    func defaultFont() {
        let c = TerminalConfig()
        #expect(c.fontName == "Menlo")
        #expect(c.fontSize == 13)
    }

    @Test("default background is dark")
    func defaultBackground() {
        let c = TerminalConfig()
        #expect(c.backgroundColorHex == "#1e1e1e")
    }

    @Test("claude path resolves via which (or fallback when not installed)")
    func claudePathResolves() {
        let c = TerminalConfig()
        // System-dependent: may be nil on systems without claude
        // We just verify the resolver runs without crashing
        _ = c.resolvedClaudePath
    }

    @Test("custom claude path overrides which")
    func customClaudePath() {
        let c = TerminalConfig(claudePathOverride: "/opt/homebrew/bin/claude")
        #expect(c.resolvedClaudePath == "/opt/homebrew/bin/claude")
    }

    // #33 — claude discovery via the hydrated login-shell PATH (a Finder launch
    // has the bare launchd PATH, which excludes ~/.local/bin etc.).

    @Test("searchPath finds claude on the hydrated PATH when the bare PATH misses it (#33)")
    func searchPathFindsClaudeOnHydratedPath() {
        // The exact #33 scenario: bare PATH has no claude; the login-shell PATH
        // includes ~/.local/bin which does.
        let hydratedPath = "/usr/bin:/bin:/Users/x/.local/bin"
        let found = TerminalConfig.searchPath(
            for: "claude",
            in: hydratedPath,
            isExecutable: { $0 == "/Users/x/.local/bin/claude" }
        )
        #expect(found == "/Users/x/.local/bin/claude")
    }

    @Test("searchPath honors PATH order — first match wins")
    func searchPathFirstMatchWins() {
        let found = TerminalConfig.searchPath(
            for: "claude",
            in: "/a:/b",
            isExecutable: { $0 == "/a/claude" || $0 == "/b/claude" }
        )
        #expect(found == "/a/claude")
    }

    @Test("searchPath returns nil for nil/empty PATH or no executable match")
    func searchPathNilCases() {
        #expect(TerminalConfig.searchPath(for: "claude", in: nil, isExecutable: { _ in true }) == nil)
        #expect(TerminalConfig.searchPath(for: "claude", in: "", isExecutable: { _ in true }) == nil)
        #expect(TerminalConfig.searchPath(for: "claude", in: "/a:/b", isExecutable: { _ in false }) == nil)
    }

    @Test("searchPath skips empty PATH components (leading/double colons)")
    func searchPathSkipsEmptyComponents() {
        let found = TerminalConfig.searchPath(
            for: "claude",
            in: "::/a",
            isExecutable: { $0 == "/a/claude" }
        )
        #expect(found == "/a/claude")
    }
}
