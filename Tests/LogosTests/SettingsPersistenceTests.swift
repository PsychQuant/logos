import Testing
import Foundation
@testable import Logos

@Suite("SettingsPersistence", .serialized)
struct SettingsPersistenceTests {

    struct TestSettings: Codable, Equatable {
        let n: Int
        let s: String
    }

    @Test("save then load returns same value")
    func roundtrip() throws {
        let dir = NSTemporaryDirectory() + "logos-sp-\(UUID().uuidString)"
        let store = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let original = TestSettings(n: 42, s: "hello")
        try store.save(original, to: "test.json")
        let loaded: TestSettings? = try store.load(from: "test.json")
        #expect(loaded == original)
    }

    @Test("load missing returns nil")
    func loadMissing() throws {
        let dir = NSTemporaryDirectory() + "logos-sp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = SettingsPersistence(directory: dir)
        let loaded: TestSettings? = try store.load(from: "nonexistent.json")
        #expect(loaded == nil)
    }

    @Test("save creates directory if needed")
    func createsDir() throws {
        let baseDir = NSTemporaryDirectory() + "logos-sp-\(UUID().uuidString)"
        let dir = "\(baseDir)/nested/path"
        let store = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: baseDir) }
        try store.save(TestSettings(n: 1, s: "x"), to: "x.json")
        #expect(FileManager.default.fileExists(atPath: "\(dir)/x.json"))
    }
}
