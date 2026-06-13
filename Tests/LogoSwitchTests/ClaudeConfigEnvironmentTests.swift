import Testing
import Foundation
import LogoSwitch

/// Direct tests for the extracted per-account env transform (#12/#21). These pin
/// the isolation contract at the pure-function level — `ClaudeProcessConfigTests`
/// exercises the same logic through the descriptor, but this is the primitive.
@Suite("ClaudeConfigEnvironment")
struct ClaudeConfigEnvironmentTests {

    @Test("forces TERM and defaults LC_ALL")
    func termAndLocale() {
        let env = ClaudeConfigEnvironment.apply(base: ["PATH": "/usr/bin"], configDir: nil)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["LC_ALL"] == "en_US.UTF-8")
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test("preserves an explicitly-set LC_ALL")
    func preservesLocale() {
        let env = ClaudeConfigEnvironment.apply(base: ["LC_ALL": "ja_JP.UTF-8"], configDir: nil)
        #expect(env["LC_ALL"] == "ja_JP.UTF-8")
    }

    @Test("configDir sets BOTH CLAUDE_* config-dir vars (#12)")
    func setsBothConfigDirs() {
        let env = ClaudeConfigEnvironment.apply(base: [:], configDir: "/acc/.claude")
        #expect(env["CLAUDE_CONFIG_DIR"] == "/acc/.claude")
        #expect(env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "/acc/.claude")
    }

    @Test("nil configDir applies no override (non-account spawn)")
    func nilConfigDirNoOverride() {
        let env = ClaudeConfigEnvironment.apply(base: ["PATH": "/usr/bin"], configDir: nil)
        #expect(env["CLAUDE_CONFIG_DIR"] == nil)
        #expect(env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
    }

    // #12: an inherited EMPTY CLAUDE_SECURESTORAGE_CONFIG_DIR collapses claude's
    // credential service name back to the shared bare entry — it must be stripped,
    // not passed through, even on a non-account spawn.
    @Test("strips an inherited empty CLAUDE_SECURESTORAGE_CONFIG_DIR (collapse guard)")
    func stripsEmptySecurestorage() {
        let env = ClaudeConfigEnvironment.apply(
            base: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": ""],
            configDir: nil
        )
        #expect(env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
    }

    // #21: HOME is the login-keychain anchor — never overridden.
    @Test("never touches HOME (#21)")
    func neverTouchesHome() {
        let env = ClaudeConfigEnvironment.apply(
            base: ["HOME": "/Users/realuser"],
            configDir: "/acc/.claude"
        )
        #expect(env["HOME"] == "/Users/realuser")
    }

    // #33 guards #12: a stale CLAUDE_CONFIG_DIR from the hydrated login-shell env
    // must lose to the per-account dir.
    @Test("per-account dir beats a stale base value (#33 guards #12)")
    func accountBeatsStaleBase() {
        let env = ClaudeConfigEnvironment.apply(
            base: ["CLAUDE_CONFIG_DIR": "/Users/realuser/.claude",
                   "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/Users/realuser/.claude"],
            configDir: "/acc/.claude"
        )
        #expect(env["CLAUDE_CONFIG_DIR"] == "/acc/.claude")
        #expect(env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "/acc/.claude")
    }
}
