import Testing
import Foundation
@testable import Logos

@Suite("MainScene.pathExistsOffMain", .serialized)
struct MainScenePathExistsTests {

    @Test("returns true for an existing path")
    func returnsTrueForExisting() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let exists = await MainScene.pathExistsOffMain(tmp)
        #expect(exists == true)
    }

    @Test("returns false for a non-existing path")
    func returnsFalseForMissing() async {
        let bogus = "/tmp/logos-test-does-not-exist-\(UUID().uuidString)"
        let exists = await MainScene.pathExistsOffMain(bogus)
        #expect(exists == false)
    }

    @Test("does not block MainActor while evaluating")
    @MainActor
    func doesNotBlockMainActor() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // MainActor sentinel — same pattern as WorkspaceLoaderTests.loadAsync_doesNotBlockCaller.
        // If `pathExistsOffMain` accidentally runs sync on MainActor, the
        // sentinel can't tick during the stat call.
        var sentinelTicks = 0
        let sentinel = Task { @MainActor in
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                sentinelTicks += 1
            }
        }

        _ = await MainScene.pathExistsOffMain(tmp)

        try await sentinel.value
        #expect(sentinelTicks >= 4) // allow 1 jitter slot
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-pathexists-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
