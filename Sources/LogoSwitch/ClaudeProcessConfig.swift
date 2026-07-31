import Foundation

public struct ClaudeProcessConfig: Sendable {

    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?
    public let account: Account?

    public init(
        executablePath: String,
        account: Account? = nil,
        extraArgs: [String] = [],
        workingDirectory: String? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        gatewayBaseURL: URL? = nil
    ) {
        self.executablePath = executablePath
        self.account = account

        // Default args: empty. Sub-plan D's AutoHandleEngine intercepts
        // permission prompts and answers per-rule, so we no longer need
        // --dangerously-skip-permissions globally. Callers can still pass
        // it via extraArgs for opt-in fallback.
        let defaultArgs: [String] = []
        self.arguments = defaultArgs + extraArgs

        self.workingDirectory = workingDirectory

        // Per-account credential isolation (#12) + #21 HOME-not-overridden +
        // the empty-securestorage collapse guard all live in the single pure
        // transform, so this descriptor just supplies the base env + the
        // account's spawn config dir. `spawnConfigDir` is nil for a non-account
        // spawn AND for a system-default ("main") account (#54) — both fall
        // through to the system ~/.claude; an isolated account gets its own dir.
        // `gatewayBaseURL` is resolved by the caller (the pane awaits GatewayPool
        // before building this descriptor — a SwiftUI body cannot await). nil means
        // "no gateway", which the transform turns into a STRIP so no account can
        // inherit another's gateway from the login-shell env.
        self.environment = ClaudeConfigEnvironment.apply(
            base: baseEnvironment,
            configDir: account.flatMap(\.spawnConfigDir),
            gatewayBaseURL: gatewayBaseURL
        )
    }
}
