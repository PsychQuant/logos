import Testing
import Foundation
@testable import Logos

@Suite("ClaudeProcessConfig", .serialized)
@MainActor
struct ClaudeProcessConfigTests {

    @Test("default args is empty (AutoHandleEngine handles prompts)")
    func defaultArgsEmpty() {
        let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
        // D-Task 5: --dangerously-skip-permissions removed. AutoHandleEngine
        // intercepts permission prompts and answers per hardcoded rule.
        #expect(cfg.arguments.isEmpty)
        #expect(!cfg.arguments.contains("--dangerously-skip-permissions"))
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

    // E-Task 4: per-account HOME injection

    @Test("HOME overridden when account provided")
    func homeOverride() {
        let account = Account(id: "test-acc", label: "work")
        let cfg = ClaudeProcessConfig(
            executablePath: "/usr/local/bin/claude",
            account: account
        )
        #expect(cfg.environment["HOME"] == account.homeDirectoryPath)
        #expect(cfg.environment["HOME"]?.hasSuffix("/.logos/accounts/test-acc") == true)
    }

    @Test("HOME unchanged when no account")
    func homeNoAccount() {
        let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
        let processHome = ProcessInfo.processInfo.environment["HOME"]
        #expect(cfg.environment["HOME"] == processHome)
    }
}
