import Foundation

public enum GatewayProcessError: Error, Equatable {
    case launchFailed(String)
    case readinessTimedOut(port: UInt16)
}

/// One supervised gateway child.
///
/// Readiness is a TCP connect probe against the assigned port, deliberately NOT a
/// parse of the child's stdout: the gateway command is user-configurable, so any
/// dependence on one proxy's log format would break the moment it is pointed at a
/// different implementation. "Something is accepting connections on the port we
/// assigned" is the only implementation-independent readiness signal.
public actor GatewayProcess {

    public let descriptor: GatewayDescriptor

    private var process: Process?

    /// How many times a child has been launched. Exposed so supervision is
    /// observable without reaching into `Process`.
    public private(set) var launchCount = 0

    /// Set by `terminate()` so a deliberate stop is never mistaken for a crash.
    private var stopping = false

    private var restartAttempt = 0

    /// Backoff schedule for crash restarts. Bounded: after the last step the
    /// gateway stays down and the caller's failure policy takes over. An unbounded
    /// retry against a genuinely broken command would spin forever.
    private static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]

    public init(descriptor: GatewayDescriptor) {
        self.descriptor = descriptor
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    public func start(readinessTimeout: Duration = .seconds(10)) async throws {
        guard !isRunning else { return }

        try? FileManager.default.createDirectory(
            atPath: descriptor.stateDirectory,
            withIntermediateDirectories: true
        )

        guard let executable = descriptor.command.first else {
            throw GatewayProcessError.launchFailed("empty command")
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = Array(descriptor.command.dropFirst())
        child.environment = ProcessInfo.processInfo.environment.merging(
            descriptor.environment
        ) { _, overlay in overlay }
        // The child's own output is noise in the app log; the readiness probe and
        // exit status carry everything the pool acts on.
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            throw GatewayProcessError.launchFailed(error.localizedDescription)
        }

        process = child
        launchCount += 1
        restartAttempt = 0

        // Fires on an arbitrary thread, so it may only hop back into the actor.
        child.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleUnexpectedExit() }
        }

        GatewayLog.process.notice(
            "gateway spawned — account=\(self.descriptor.accountID, privacy: .public) port=\(self.descriptor.port, privacy: .public)"
        )

        try await waitUntilReady(timeout: readinessTimeout)
    }

    private func waitUntilReady(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Self.canConnect(port: descriptor.port) {
                GatewayLog.process.notice(
                    "gateway ready — account=\(self.descriptor.accountID, privacy: .public) port=\(self.descriptor.port, privacy: .public)"
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        GatewayLog.process.error(
            "gateway readiness timed out — account=\(self.descriptor.accountID, privacy: .public) port=\(self.descriptor.port, privacy: .public)"
        )
        throw GatewayProcessError.readinessTimedOut(port: descriptor.port)
    }

    /// Relaunch after a crash, with bounded backoff.
    private func handleUnexpectedExit() async {
        guard !stopping else { return }
        guard restartAttempt < Self.backoff.count else {
            GatewayLog.process.error(
                "gateway restart budget exhausted — account=\(self.descriptor.accountID, privacy: .public)"
            )
            process = nil
            return
        }

        let delay = Self.backoff[restartAttempt]
        restartAttempt += 1
        let attempt = restartAttempt
        GatewayLog.process.notice(
            "gateway exited unexpectedly, restarting — account=\(self.descriptor.accountID, privacy: .public) attempt=\(attempt, privacy: .public)"
        )

        try? await Task.sleep(for: delay)
        guard !stopping else { return }

        process = nil
        try? await start()
        // `start()` resets the counter on success; restore it so the budget is
        // bounded across the whole supervision episode rather than per launch.
        restartAttempt = attempt
    }

    public func terminate(grace: Duration = .seconds(3)) async {
        stopping = true
        defer { stopping = false }

        guard let child = process, child.isRunning else {
            process = nil
            return
        }
        child.terminationHandler = nil
        child.terminate()   // SIGTERM

        let deadline = ContinuousClock.now.advanced(by: grace)
        while child.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
        process = nil

        GatewayLog.process.notice(
            "gateway terminated — account=\(self.descriptor.accountID, privacy: .public)"
        )
    }

    /// Single TCP connect attempt against the loopback port.
    static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
