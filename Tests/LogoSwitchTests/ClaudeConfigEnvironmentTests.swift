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

/// Transport-layer routing (spec 2026-07-31). Separate suite from the config-dir
/// contract above because it answers a different question: not "whose credentials"
/// but "through whose gateway".
@Suite("ClaudeConfigEnvironment gateway")
struct ClaudeConfigEnvironmentGatewayTests {

    @Test("injects the gateway base URL when given")
    func injectsGatewayBaseURL() {
        let env = ClaudeConfigEnvironment.apply(
            base: [:],
            configDir: "/tmp/acc/.claude",
            gatewayBaseURL: URL(string: "http://127.0.0.1:51234")!
        )
        #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:51234")
    }

    /// The mirror of the #54 stale-CLAUDE_CONFIG_DIR strip. Without it, launching
    /// Logos from a shell that exports ANTHROPIC_BASE_URL makes every account
    /// silently inherit one shared gateway — the exact bug this feature fixes,
    /// re-entering through the back door.
    @Test("strips an inherited base URL when there is no gateway")
    func stripsInheritedBaseURL() {
        let env = ClaudeConfigEnvironment.apply(
            base: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"],
            configDir: "/tmp/acc/.claude",
            gatewayBaseURL: nil
        )
        #expect(env["ANTHROPIC_BASE_URL"] == nil)
    }

    /// Omitting the argument must behave exactly like passing nil, so no existing
    /// call site accidentally leaks an inherited value.
    @Test("the default argument also strips")
    func defaultArgumentStrips() {
        let env = ClaudeConfigEnvironment.apply(
            base: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"],
            configDir: nil
        )
        #expect(env["ANTHROPIC_BASE_URL"] == nil)
    }

    /// A per-account gateway must beat an inherited one, mirroring how the
    /// per-account config dir beats a stale base value.
    @Test("the gateway beats a stale base value")
    func gatewayBeatsStaleBase() {
        let env = ClaudeConfigEnvironment.apply(
            base: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"],
            configDir: "/acc/.claude",
            gatewayBaseURL: URL(string: "http://127.0.0.1:51234")!
        )
        #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:51234")
    }

    /// The pre-existing config-dir contract is untouched by the new parameter.
    @Test("config-dir behavior is unchanged")
    func configDirUnchanged() {
        let isolated = ClaudeConfigEnvironment.apply(
            base: [:], configDir: "/tmp/acc/.claude",
            gatewayBaseURL: URL(string: "http://127.0.0.1:51234")!)
        #expect(isolated["CLAUDE_CONFIG_DIR"] == "/tmp/acc/.claude")
        #expect(isolated["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "/tmp/acc/.claude")

        let systemDefault = ClaudeConfigEnvironment.apply(
            base: ["CLAUDE_CONFIG_DIR": "/stale", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/stale"],
            configDir: nil)
        #expect(systemDefault["CLAUDE_CONFIG_DIR"] == nil)
        #expect(systemDefault["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
    }
}
