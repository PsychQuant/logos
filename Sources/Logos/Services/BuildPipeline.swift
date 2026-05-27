import Foundation

public actor BuildPipeline {

    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    public init() {}

    public func run(command: String, workingDirectory: String) async throws -> Result {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: Result(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
            do {
                try process.run()
                // Hook cancellation: when parent Task cancels, terminate
                Task {
                    while !Task.isCancelled, process.isRunning {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if process.isRunning { process.terminate() }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
