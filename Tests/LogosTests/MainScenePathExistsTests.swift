import Testing
import Foundation
@testable import Logos

@Suite("MainScene.directoryExistsOffMain", .serialized)
struct MainScenePathExistsTests {

    @Test("returns true for an existing directory")
    func returnsTrueForExistingDir() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let exists = await MainScene.directoryExistsOffMain(tmp)
        #expect(exists == true)
    }

    @Test("returns false for a non-existing path")
    func returnsFalseForMissing() async {
        let bogus = "/tmp/logos-test-does-not-exist-\(UUID().uuidString)"
        let exists = await MainScene.directoryExistsOffMain(bogus)
        #expect(exists == false)
    }

    @Test("returns false for an existing FILE (not a directory) — #9")
    func returnsFalseForFile() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let file = "\(tmp)/became-a-file.txt"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)

        // A persisted path that turned into a regular file must NOT validate —
        // otherwise the loader would return a single-file root (nonsensical UI).
        let exists = await MainScene.directoryExistsOffMain(file)
        #expect(exists == false)
    }

    @Test("does not block MainActor while evaluating")
    @MainActor
    func doesNotBlockMainActor() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var sentinelTicks = 0
        let sentinel = Task { @MainActor in
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                sentinelTicks += 1
            }
        }

        _ = await MainScene.directoryExistsOffMain(tmp)

        try await sentinel.value
        #expect(sentinelTicks >= 4) // allow 1 jitter slot
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-direxists-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
