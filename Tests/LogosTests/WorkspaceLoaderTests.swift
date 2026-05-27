import Testing
import Foundation
@testable import Logos

@Suite("WorkspaceLoader", .serialized)
struct WorkspaceLoaderTests {

    @Test("loads simple flat workspace")
    func flat() throws {
        let tmp = try makeTempDir()
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: "\(tmp)/b.swift", atomically: true, encoding: .utf8)

        let loader = WorkspaceLoader()
        let tree = try loader.load(rootPath: tmp)
        #expect(tree.kind == .directory)
        #expect(tree.children?.map(\.displayName).sorted() == ["a.txt", "b.swift"])

        try FileManager.default.removeItem(atPath: tmp)
    }

    @Test("recurses into subdirs")
    func recurses() throws {
        let tmp = try makeTempDir()
        try FileManager.default.createDirectory(atPath: "\(tmp)/sub", withIntermediateDirectories: true)
        try "z".write(toFile: "\(tmp)/sub/c.swift", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp)
        let sub = tree.children?.first { $0.displayName == "sub" }
        #expect(sub?.kind == .directory)
        #expect(sub?.children?.first?.displayName == "c.swift")

        try FileManager.default.removeItem(atPath: tmp)
    }

    @Test("skips noise directories")
    func skipsNoise() throws {
        let tmp = try makeTempDir()
        try FileManager.default.createDirectory(atPath: "\(tmp)/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(tmp)/node_modules", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/keep.swift", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp)
        let names = tree.children?.map(\.displayName).sorted() ?? []
        #expect(names == ["keep.swift"])

        try FileManager.default.removeItem(atPath: tmp)
    }

    @Test("loads sorted alphabetically with dirs first")
    func sortedDirsFirst() throws {
        let tmp = try makeTempDir()
        try FileManager.default.createDirectory(atPath: "\(tmp)/zsub", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp)
        let names = tree.children?.map(\.displayName) ?? []
        #expect(names == ["zsub", "a.txt"])

        try FileManager.default.removeItem(atPath: tmp)
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
