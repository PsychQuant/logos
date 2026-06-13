import Testing
import Foundation
@testable import LogoSwitch

/// Stub-driven — no real claude needed. `@testable` for the internal runner-
/// injecting init + the internal `ProcessRunner`.
@Suite("ClaudeAuthInvoker", .serialized)
struct ClaudeAuthInvokerTests {

    private let account = Account(id: "acc-1", label: "work")

    private func invoker(_ runner: ProcessRunner) -> ClaudeAuthInvoker {
        ClaudeAuthInvoker(binaryPath: "/usr/local/bin/claude", baseEnvironment: ["HOME": "/Users/x"], runner: runner)
    }

    private func ok(_ json: String) -> ProcessRunner {
        .stub { _ in .init(exitCode: 0, stdout: Data(json.utf8), timedOut: false) }
    }

    // MARK: parseStatus

    @Test("parseStatus reads loggedIn/email/subscriptionType")
    func parsesFullStatus() {
        let s = ClaudeAuthInvoker.parseStatus(Data(#"{"loggedIn":true,"email":"u@e.com","subscriptionType":"pro"}"#.utf8))
        #expect(s == AuthStatus(loggedIn: true, email: "u@e.com", subscriptionType: "pro"))
    }

    @Test("parseStatus returns nil on malformed JSON or missing loggedIn")
    func parseStatusNil() {
        #expect(ClaudeAuthInvoker.parseStatus(Data("not json".utf8)) == nil)
        #expect(ClaudeAuthInvoker.parseStatus(Data(#"{"email":"u@e.com"}"#.utf8)) == nil)
    }

    // MARK: status (fail-closed)

    @Test("status parses a logged-in JSON result")
    func statusLoggedIn() {
        let s = invoker(ok(#"{"loggedIn":true,"email":"u@e.com","subscriptionType":"max"}"#)).status(for: account)
        #expect(s == AuthStatus(loggedIn: true, email: "u@e.com", subscriptionType: "max"))
    }

    @Test("status collapses non-zero exit to .unknown")
    func statusNonZero() {
        let runner = ProcessRunner.stub { _ in .init(exitCode: 1, stdout: Data(#"{"loggedIn":true}"#.utf8), timedOut: false) }
        #expect(invoker(runner).status(for: account) == .unknown)
    }

    @Test("status collapses a timeout to .unknown")
    func statusTimeout() {
        let runner = ProcessRunner.stub { _ in .init(exitCode: 0, stdout: Data(), timedOut: true) }
        #expect(invoker(runner).status(for: account) == .unknown)
    }

    @Test("status collapses malformed stdout to .unknown")
    func statusMalformed() {
        #expect(invoker(ok("garbage")).status(for: account) == .unknown)
    }

    @Test("status invokes `auth status --json`")
    func statusArgv() {
        // Returns logged-in ONLY for the exact expected argv; otherwise garbage →
        // .unknown. So loggedIn==true proves the argv.
        let runner = ProcessRunner.stub { args in
            args == ["auth", "status", "--json"]
                ? .init(exitCode: 0, stdout: Data(#"{"loggedIn":true}"#.utf8), timedOut: false)
                : .init(exitCode: 0, stdout: Data("x".utf8), timedOut: false)
        }
        #expect(invoker(runner).status(for: account).loggedIn == true)
    }

    // MARK: login / logout

    @Test("login succeeds on exit 0")
    func loginSuccess() {
        let r = invoker(.stub { _ in .init(exitCode: 0, stdout: Data(), timedOut: false) }).login(for: account)
        #expect(r == AuthResult(success: true, message: nil))
    }

    @Test("login reports failure with the exit code")
    func loginFailure() {
        let r = invoker(.stub { _ in .init(exitCode: 7, stdout: Data(), timedOut: false) }).login(for: account)
        #expect(r.success == false)
        #expect(r.message == "login exited 7")
    }

    @Test("login reports timeout")
    func loginTimeout() {
        let r = invoker(.stub { _ in .init(exitCode: -1, stdout: Data(), timedOut: true) }).login(for: account)
        #expect(r.success == false)
        #expect(r.message == "login timed out")
    }

    // RED LINE: login must never read stdout (no URL scraping / token touch). Even
    // if claude printed the authorize URL to stdout, the AuthResult carries only
    // the exit outcome — never anything derived from stdout.
    @Test("login ignores stdout entirely (no URL leaks into the result)")
    func loginIgnoresStdout() {
        let url = "https://claude.com/cai/oauth/authorize?code=secret&redirect_uri=x"
        let r = invoker(.stub { _ in .init(exitCode: 0, stdout: Data(url.utf8), timedOut: false) }).login(for: account)
        #expect(r == AuthResult(success: true, message: nil))
        #expect(r.message?.contains("authorize") != true)
    }

    @Test("auth runs under the per-account CLAUDE_CONFIG_DIR (#12)")
    func usesPerAccountConfigDir() {
        // The runner sees the env; succeed ONLY when the account's config dir was
        // layered in — proves the invoker routes through ClaudeConfigEnvironment.
        let runner = ProcessRunner { _, _, env, _ in
            let ok = env?["CLAUDE_CONFIG_DIR"] == self.account.configDirPath
                && env?["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == self.account.configDirPath
            return .init(exitCode: ok ? 0 : 1, stdout: Data(), timedOut: false)
        }
        #expect(invoker(runner).login(for: account).success == true)
    }

    @Test("logout succeeds on exit 0")
    func logoutSuccess() {
        let r = invoker(.stub { _ in .init(exitCode: 0, stdout: Data(), timedOut: false) }).logout(for: account)
        #expect(r.success == true)
    }
}
