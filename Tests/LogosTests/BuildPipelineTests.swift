import Testing
import Foundation
@testable import Logos

@Suite("BuildPipeline", .serialized)
struct BuildPipelineTests {

    @Test("runs success command")
    func runSuccess() async throws {
        let pipeline = BuildPipeline()
        let result = try await pipeline.run(
            command: "echo hello",
            workingDirectory: "/tmp"
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("hello"))
    }

    @Test("captures stderr")
    func capturesStderr() async throws {
        let pipeline = BuildPipeline()
        let result = try await pipeline.run(
            command: "echo error >&2; exit 1",
            workingDirectory: "/tmp"
        )
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("error"))
    }
}
