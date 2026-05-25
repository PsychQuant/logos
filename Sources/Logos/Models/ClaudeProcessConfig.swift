import Foundation

public struct ClaudeProcessConfig: Sendable {

    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?

    public init(
        executablePath: String,
        extraArgs: [String] = [],
        workingDirectory: String? = nil
    ) {
        self.executablePath = executablePath

        // Default args. Auto-handle in sub-plan D will revisit these.
        let defaultArgs = ["--dangerously-skip-permissions"]
        self.arguments = defaultArgs + extraArgs

        self.workingDirectory = workingDirectory

        // Inherit user environment, force TERM for proper rendering
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        self.environment = env
    }
}
