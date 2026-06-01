import Testing
@testable import Logos

/// Coverage for the `--claude-path` launch-arg parser (#24 verify). The hook
/// itself only fires under `--ui-testing` (see `TerminalConfig.uiTestingClaudePath`);
/// this locks the pure parsing rules: both arg forms, empty-value rejection, and
/// the "next token is an option" guard.
@MainActor
@Suite("TerminalConfig --claude-path parsing")
struct TerminalConfigClaudePathArgTests {

    @Test("space form returns the path")
    func spaceForm() {
        #expect(TerminalConfig.parseClaudePathArg(from: ["bin", "--claude-path", "/x/claude"]) == "/x/claude")
    }

    @Test("equals form returns the path")
    func equalsForm() {
        #expect(TerminalConfig.parseClaudePathArg(from: ["bin", "--claude-path=/y/claude"]) == "/y/claude")
    }

    @Test("absent → nil")
    func absent() {
        #expect(TerminalConfig.parseClaudePathArg(from: ["bin", "--workspace", "/ws"]) == nil)
    }

    @Test("empty value → nil (both forms)")
    func emptyValue() {
        #expect(TerminalConfig.parseClaudePathArg(from: ["bin", "--claude-path="]) == nil)
        #expect(TerminalConfig.parseClaudePathArg(from: ["bin", "--claude-path", ""]) == nil)
    }

    @Test("next token is an option → nil (does not swallow --workspace)")
    func optionAsValue() {
        #expect(TerminalConfig.parseClaudePathArg(from: ["bin", "--claude-path", "--workspace", "/ws"]) == nil)
    }

    @Test("trailing --claude-path with no value → nil")
    func trailingNoValue() {
        #expect(TerminalConfig.parseClaudePathArg(from: ["bin", "--claude-path"]) == nil)
    }

    @Test("coexists with --workspace, returns the claude path")
    func withWorkspace() {
        #expect(
            TerminalConfig.parseClaudePathArg(from: ["bin", "--claude-path", "/c/claude", "--workspace", "/ws"]) == "/c/claude"
        )
    }
}
