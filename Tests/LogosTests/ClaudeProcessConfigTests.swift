import Testing
@testable import Logos

@Suite("ClaudeProcessConfig", .serialized)
@MainActor
struct ClaudeProcessConfigTests {

    @Test("default args includes dangerously-skip-permissions")
    func defaultArgs() {
        let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
        #expect(cfg.arguments.contains("--dangerously-skip-permissions"))
    }

    @Test("environment inherits PATH and HOME")
    func envInheritance() {
        let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
        #expect(cfg.environment["PATH"] != nil)
        #expect(cfg.environment["HOME"] != nil)
    }

    @Test("env sets TERM=xterm-256color")
    func envSetsTerm() {
        let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
        #expect(cfg.environment["TERM"] == "xterm-256color")
    }

    @Test("executable path used as argv[0]")
    func argv0() {
        let cfg = ClaudeProcessConfig(executablePath: "/opt/homebrew/bin/claude")
        #expect(cfg.executablePath == "/opt/homebrew/bin/claude")
    }

    @Test("custom args override defaults")
    func customArgs() {
        let cfg = ClaudeProcessConfig(
            executablePath: "/usr/local/bin/claude",
            extraArgs: ["--help"]
        )
        #expect(cfg.arguments.contains("--help"))
    }
}
