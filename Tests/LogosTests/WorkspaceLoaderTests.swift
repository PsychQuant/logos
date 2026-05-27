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

    // MARK: - Safety limits (Issue #2 Prong B)

    @Test("refuses root path /")
    func refusesRoot() {
        let loader = WorkspaceLoader()
        #expect(throws: WorkspaceLoader.LoaderError.refusedSystemPath("/")) {
            try loader.load(rootPath: "/")
        }
    }

    @Test("refuses system path /System")
    func refusesSystemPath() {
        let loader = WorkspaceLoader()
        #expect(throws: WorkspaceLoader.LoaderError.refusedSystemPath("/System")) {
            try loader.load(rootPath: "/System")
        }
    }

    @Test("respects maxDepth — tree depth ≤ maxDepth")
    func respectsMaxDepth() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var current = tmp
        for label in ["a","b","c","d","e","f","g","h","i","j","k","l"] {
            current = "\(current)/\(label)"
            try FileManager.default.createDirectory(atPath: current, withIntermediateDirectories: true)
        }
        try "leaf".write(toFile: "\(current)/file.txt", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader(maxDepth: 10, maxFiles: 50_000).load(rootPath: tmp)
        #expect(Self.treeDepth(tree) <= 10)
    }

    @Test("fails fast on maxFiles")
    func failsFastOnMaxFiles() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        for i in 0..<100 {
            try "x".write(toFile: "\(tmp)/file-\(i).txt", atomically: true, encoding: .utf8)
        }

        let loader = WorkspaceLoader(maxDepth: 10, maxFiles: 50)
        #expect(throws: WorkspaceLoader.LoaderError.tooManyFiles(found: 50, cap: 50)) {
            try loader.load(rootPath: tmp)
        }
    }

    @Test("skips system paths within subtree via resolved symlink")
    func skipsSystemPathsWithinSubtree() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try "x".write(toFile: "\(tmp)/keep.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: "\(tmp)/library_link",
            withDestinationPath: "/Library"
        )

        let tree = try WorkspaceLoader().load(rootPath: tmp)
        let names = tree.children?.map(\.displayName).sorted() ?? []
        #expect(names == ["keep.txt"])
    }

    private static func treeDepth(_ node: FileNode) -> Int {
        1 + (node.children?.map { treeDepth($0) }.max() ?? 0)
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
