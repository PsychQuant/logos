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

    // #21: HOME must NOT be overridden to the per-account dir. macOS resolves the
    // login keychain via $HOME ($HOME/Library/Keychains/login.keychain-db); a
    // per-account home has none, so claude's credential SecItemAdd fails with
    // 「找不到鑰匙圈來儲存」. Per-account isolation is via CLAUDE_CONFIG_DIR +
    // CLAUDE_SECURESTORAGE_CONFIG_DIR (the keychain is per-login-user), NOT HOME.
    @Test("account spawn keeps inherited HOME (keychain preserved) but isolates config dirs")
    func homeNotOverriddenForAccount() {
        let account = Account(id: "test-acc", label: "work")
        let cfg = ClaudeProcessConfig(
            executablePath: "/usr/local/bin/claude",
            account: account,
            baseEnvironment: ["HOME": "/Users/realuser", "PATH": "/usr/bin"]
        )
        // HOME stays the inherited real home — NOT the per-account dir.
        #expect(cfg.environment["HOME"] == "/Users/realuser")
        #expect(cfg.environment["HOME"] != account.homeDirectoryPath)
        // Isolation preserved via the config-dir env vars (independent of HOME).
        #expect(cfg.environment["CLAUDE_CONFIG_DIR"] == account.configDirPath)
        #expect(cfg.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == account.configDirPath)
    }

    @Test("HOME unchanged when no account")
    func homeNoAccount() {
        let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
        let processHome = ProcessInfo.processInfo.environment["HOME"]
        #expect(cfg.environment["HOME"] == processHome)
    }
}
