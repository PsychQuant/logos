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
        workingDirectory: String? = nil
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

        // Inherit user environment, force TERM, override HOME if account specified
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        if let account = account {
            // E-Task 4: per-account HOME so claude reads its credentials from
            // ~/.logos/accounts/<id>/.claude/.credentials.json instead of
            // the global ~/.claude/.credentials.json.
            env["HOME"] = account.homeDirectoryPath
        }
        self.environment = env
    }
}
