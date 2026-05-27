import Testing
import Foundation
@testable import Logos

@Suite("FileContentLoader", .serialized)
struct FileContentLoaderTests {

    @Test("loads small text file")
    func small() throws {
        let path = NSTemporaryDirectory() + "logos-fcl-\(UUID().uuidString).txt"
        try "hello\nworld".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let loader = FileContentLoader(maxBytes: 1_000_000)
        let content = try loader.load(path: path)
        #expect(content == "hello\nworld")
    }

    @Test("rejects files over max size")
    func tooLarge() throws {
        let path = NSTemporaryDirectory() + "logos-fcl-\(UUID().uuidString).txt"
        let big = String(repeating: "x", count: 1000)
        try big.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let loader = FileContentLoader(maxBytes: 100)
        #expect(throws: FileContentLoader.Error.tooLarge(actualBytes: 1000, maxBytes: 100)) {
            try loader.load(path: path)
        }
    }

    @Test("rejects non-utf8 files")
    func binaryNonUtf8() throws {
        let path = NSTemporaryDirectory() + "logos-fcl-\(UUID().uuidString).bin"
        let data = Data([0xFF, 0xFE, 0xFD, 0xFC])
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let loader = FileContentLoader(maxBytes: 1_000_000)
        #expect(throws: FileContentLoader.Error.notUtf8) {
            try loader.load(path: path)
        }
    }

    @Test("not-found surfaces clear error")
    func notFound() {
        let loader = FileContentLoader(maxBytes: 1_000)
        #expect(throws: (any Error).self) {
            try loader.load(path: "/definitely/does/not/exist/asdf")
        }
    }
}
