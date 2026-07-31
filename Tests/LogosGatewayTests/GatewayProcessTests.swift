import Foundation
import Testing
@testable import LogosGateway

/// A stand-in gateway that binds the assigned port and then idles for `seconds`.
/// Lets the readiness probe succeed without needing the real proxy installed.
private func fakeGatewayCommand(idleSeconds: Int) -> [String] {
    let script = """
    import socket, os, time
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", int(os.environ["RATE_LIMIT_PROXY_PORT"])))
    s.listen(5)
    time.sleep(\(idleSeconds))
    """
    return ["/usr/bin/env", "python3", "-c", script]
}

private func fakeDescriptor(
    accountID: String,
    port: UInt16,
    idleSeconds: Int = 60
) -> GatewayDescriptor {
    GatewayDescriptor(
        accountID: accountID,
        command: fakeGatewayCommand(idleSeconds: idleSeconds),
        port: port,
        stateDirectory: NSTemporaryDirectory(),
        upstream: GatewayDescriptor.defaultUpstream
    )
}

@Suite struct GatewayProcessTests {

    @Test func startsAndBecomesReady() async throws {
        let port = try await PortAllocator().allocate()
        let process = GatewayProcess(descriptor: fakeDescriptor(accountID: "ACC-READY", port: port))
        try await process.start(readinessTimeout: .seconds(20))
        #expect(await process.isRunning)
        await process.terminate()
    }

    @Test func terminateStopsTheChild() async throws {
        let port = try await PortAllocator().allocate()
        let process = GatewayProcess(descriptor: fakeDescriptor(accountID: "ACC-STOP", port: port))
        try await process.start(readinessTimeout: .seconds(20))
        await process.terminate()
        #expect(await process.isRunning == false)
    }

    /// A command that exits immediately never binds, so readiness must time out
    /// rather than hang or falsely report success.
    @Test func timesOutWhenNothingEverBinds() async throws {
        let port = try await PortAllocator().allocate()
        let descriptor = GatewayDescriptor(
            accountID: "ACC-DEAD",
            command: ["/usr/bin/true"],
            port: port,
            stateDirectory: NSTemporaryDirectory()
        )
        let process = GatewayProcess(descriptor: descriptor)
        await #expect(throws: GatewayProcessError.self) {
            try await process.start(readinessTimeout: .milliseconds(800))
        }
        await process.terminate()
    }

    /// A command that cannot be executed at all must surface as launchFailed, not
    /// as a readiness timeout — the two call for different operator action.
    @Test func reportsLaunchFailureForAMissingExecutable() async throws {
        let port = try await PortAllocator().allocate()
        let descriptor = GatewayDescriptor(
            accountID: "ACC-MISSING",
            command: ["/nonexistent/definitely-not-here"],
            port: port,
            stateDirectory: NSTemporaryDirectory()
        )
        let process = GatewayProcess(descriptor: descriptor)
        await #expect(throws: GatewayProcessError.self) {
            try await process.start(readinessTimeout: .milliseconds(500))
        }
        #expect(await process.launchCount == 0)
    }
}

@Suite struct GatewaySupervisionTests {

    /// A child that dies on its own must come back, or every request from that
    /// account fails until the window is reopened.
    @Test func restartsAfterAnUnexpectedExit() async throws {
        let port = try await PortAllocator().allocate()
        let process = GatewayProcess(
            descriptor: fakeDescriptor(accountID: "ACC-CRASH", port: port, idleSeconds: 1))
        try await process.start(readinessTimeout: .seconds(20))
        #expect(await process.launchCount == 1)

        // Child self-exits at ~1s; first backoff step is 1s; then a fresh start.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await process.launchCount < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await process.launchCount >= 2, "crashed gateway was never restarted")

        await process.terminate()
    }

    /// A deliberate terminate() must NOT be mistaken for a crash.
    @Test func doesNotRestartAfterDeliberateTermination() async throws {
        let port = try await PortAllocator().allocate()
        let process = GatewayProcess(
            descriptor: fakeDescriptor(accountID: "ACC-CLEAN", port: port))
        try await process.start(readinessTimeout: .seconds(20))
        await process.terminate()

        try await Task.sleep(for: .seconds(3))
        #expect(await process.launchCount == 1, "deliberate stop triggered a restart")
        #expect(await process.isRunning == false)
    }
}
