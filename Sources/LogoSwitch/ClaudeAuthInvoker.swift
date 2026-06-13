import Foundation

/// Parsed `claude auth status` output. `email`/`subscriptionType` are
/// display-only and must NEVER be logged in clear (#22) — they are PII from
/// claude's auth state, not Logos's to surface to the unified log.
public struct AuthStatus: Sendable, Equatable, Codable {
    public let loggedIn: Bool
    public let email: String?
    public let subscriptionType: String?

    public init(loggedIn: Bool, email: String?, subscriptionType: String?) {
        self.loggedIn = loggedIn
        self.email = email
        self.subscriptionType = subscriptionType
    }

    /// The fail-closed value: any failure (non-zero exit, timeout, malformed
    /// JSON) collapses here rather than throwing.
    public static let unknown = AuthStatus(loggedIn: false, email: nil, subscriptionType: nil)
}

public struct AuthResult: Sendable, Equatable {
    public let success: Bool
    public let message: String?
    public init(success: Bool, message: String? = nil) {
        self.success = success
        self.message = message
    }
}

/// Invokes claude's OWN `auth login/logout/status` subcommands under a given
/// account's config dir (PsychQuant/logos#34). This is the sanctioned, BAT-style
/// auth path: claude opens its own browser + runs its own OAuth callback
/// listener; LogoSwitch only spawns the subcommand and observes the exit.
///
/// Red line: it never reads, copies, decrypts, moves, or refreshes a token;
/// never reads stdout for the authorize URL; never proxies the OAuth callback;
/// never calls the Anthropic API. claude owns the entire credential lifecycle —
/// LogoSwitch only sets the per-account `CLAUDE_*_CONFIG_DIR` (via the audited
/// `ClaudeConfigEnvironment.apply`) and waits.
public struct ClaudeAuthInvoker: Sendable {

    public enum Timeout {
        /// `auth status` / `auth logout` exit ~immediately.
        public static let status: TimeInterval = 10
        /// `auth login` waits for the real-user browser OAuth round-trip (BAT's
        /// ceiling). Generous, but bounded so a stuck flow eventually fails.
        public static let login: TimeInterval = 180
    }

    private let binaryPath: String
    private let baseEnvironment: [String: String]
    private let runner: ProcessRunner

    /// Production. `baseEnvironment` is a RESOLVED snapshot (the caller hydrates
    /// `LoginShellEnvironment.resolve()` on the main actor and passes the value),
    /// NOT a closure reaching back to a main-actor singleton — so `login` can run
    /// off-main in a `Task` without an isolation hop (the Swift6 verify must-fix).
    public init(binaryPath: String, baseEnvironment: [String: String]) {
        self.init(binaryPath: binaryPath, baseEnvironment: baseEnvironment, runner: .live)
    }

    /// Test seam (internal): inject a stub `ProcessRunner`.
    init(binaryPath: String, baseEnvironment: [String: String], runner: ProcessRunner) {
        self.binaryPath = binaryPath
        self.baseEnvironment = baseEnvironment
        self.runner = runner
    }

    /// `claude auth status --json` under `account`'s config dir. Fail-closed:
    /// non-zero exit / timeout / malformed JSON all collapse to `.unknown`.
    public func status(for account: Account) -> AuthStatus {
        let r = runner.run(binaryPath, ["auth", "status", "--json"], env(for: account), Timeout.status)
        guard r.exitCode == 0, !r.timedOut else { return .unknown }
        return Self.parseStatus(r.stdout) ?? .unknown
    }

    /// `claude auth login` under `account`'s config dir. Waits for the child to
    /// exit ONLY — stdout is never inspected (no URL scraping), the callback is
    /// never proxied, the token is never touched.
    @discardableResult
    public func login(for account: Account) -> AuthResult {
        let r = runner.run(binaryPath, ["auth", "login"], env(for: account), Timeout.login)
        let result = Self.outcome(exitCode: r.exitCode, timedOut: r.timedOut, op: "login")
        // Outcome bool only — never the email/URL/token (#22).
        LogoSwitchLog.auth.notice("claude auth login finished — success=\(result.success, privacy: .public)")
        return result
    }

    /// `claude auth logout` under `account`'s config dir. Token deletion is
    /// claude's job; we invoke + report the exit.
    @discardableResult
    public func logout(for account: Account) -> AuthResult {
        let r = runner.run(binaryPath, ["auth", "logout"], env(for: account), Timeout.status)
        let result = Self.outcome(exitCode: r.exitCode, timedOut: r.timedOut, op: "logout")
        LogoSwitchLog.auth.notice("claude auth logout finished — success=\(result.success, privacy: .public)")
        return result
    }

    /// Per-account env via the audited isolation primitive — the ONLY env
    /// mutation (no free-form passthrough), so auth runs under the right
    /// per-account config dir (#12).
    private func env(for account: Account) -> [String: String] {
        ClaudeConfigEnvironment.apply(base: baseEnvironment, configDir: account.configDirPath)
    }

    private static func outcome(exitCode: Int32, timedOut: Bool, op: String) -> AuthResult {
        if timedOut { return AuthResult(success: false, message: "\(op) timed out") }
        return AuthResult(success: exitCode == 0,
                          message: exitCode == 0 ? nil : "\(op) exited \(exitCode)")
    }

    /// Parse `claude auth status --json`. Returns nil on any structural problem
    /// (caller → `.unknown`). Reads only the three known keys.
    static func parseStatus(_ data: Data) -> AuthStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = obj["loggedIn"] as? Bool else { return nil }
        return AuthStatus(
            loggedIn: loggedIn,
            email: obj["email"] as? String,
            subscriptionType: obj["subscriptionType"] as? String
        )
    }
}
