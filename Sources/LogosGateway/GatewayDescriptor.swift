import Foundation

/// Everything needed to run one account's gateway.
///
/// A value type on purpose: the pool decides *what* to run, `GatewayProcess`
/// decides *how*, and neither needs to reach into the other.
public struct GatewayDescriptor: Sendable, Equatable {

    public let accountID: String
    /// Full argv. Never a shell string — nothing here is word-split by a shell,
    /// so a path containing spaces needs no quoting.
    public let command: [String]
    public let port: UInt16
    public let stateDirectory: String
    public let upstream: URL

    public init(
        accountID: String,
        command: [String],
        port: UInt16,
        stateDirectory: String,
        upstream: URL = GatewayDescriptor.defaultUpstream
    ) {
        self.accountID = accountID
        self.command = command
        self.port = port
        self.stateDirectory = stateDirectory
        self.upstream = upstream
    }

    public static let defaultUpstream = URL(string: "https://api.anthropic.com")!

    /// What the spawned claude gets as `ANTHROPIC_BASE_URL`.
    public var baseURL: URL {
        // Infallible: fixed scheme, literal IPv4 loopback, numeric port.
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// The child's environment overlay — the three knobs the claude-hot-limit
    /// proxy already reads. Without them it would fall back to port 8787 and the
    /// shared `~/.cache/claude-hot-limit/rate-state.jsonl`, re-joining every other
    /// account in one rate-limit bucket, which is the bug this feature removes.
    public var environment: [String: String] {
        [
            "RATE_LIMIT_PROXY_PORT": String(port),
            "RATE_LIMIT_PROXY_UPSTREAM": upstream.absoluteString,
            "CLAUDE_HOT_LIMIT_DATA": stateDirectory
        ]
    }

    /// Per-account proxy state, nested inside the account's own directory so
    /// `AccountReaper`'s existing whole-directory removal cleans it up too.
    public static func stateDirectory(forAccountHome home: String) -> String {
        "\(home)/hot-limit"
    }
}
