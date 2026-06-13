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

    // claude binary discovery (searchPath / resolve order) moved to LogoSwitch's
    // ClaudeBinaryResolver in #34 — see ClaudeBinaryResolverTests. TerminalConfig
    // now delegates resolvedClaudePath to it (covered by customClaudePath above).
}
