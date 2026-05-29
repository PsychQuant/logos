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
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
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

        // Inherit user environment, force TERM. `baseEnvironment` is injectable
        // for tests; production passes the real process environment.
        var env = baseEnvironment
        env["TERM"] = "xterm-256color"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"

        // An inherited *empty* CLAUDE_SECURESTORAGE_CONFIG_DIR silently collapses
        // claude's credential service name back to the shared bare entry
        // (`Claude Code-credentials`), defeating per-account isolation — never let
        // an empty value through (PsychQuant/logos#12).
        if env["CLAUDE_SECURESTORAGE_CONFIG_DIR"]?.isEmpty == true {
            env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        }

        if let account = account {
            // Per-account credential isolation (#12). claude keys its Keychain
            // service name on the secure-storage config dir, which it resolves
            // from CLAUDE_SECURESTORAGE_CONFIG_DIR first and CLAUDE_CONFIG_DIR
            // only as a fallback. Set BOTH to the same per-account dir so claude
            // stores/reads creds under `Claude Code-credentials-<hash>` instead
            // of the shared bare entry. HOME stays per-account for history
            // isolation; it does NOT affect the credential service name.
            let configDir = account.configDirPath
            env["HOME"] = account.homeDirectoryPath
            env["CLAUDE_CONFIG_DIR"] = configDir
            env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = configDir
        }
        self.environment = env
    }
}
