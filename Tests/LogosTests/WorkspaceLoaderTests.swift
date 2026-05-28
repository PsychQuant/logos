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

    // MARK: - User-relative TCC skip (Issue #7)

    @Test("skips TCC-protected children when walking home")
    func walk_skipsTCCChildrenOfHome() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }

        for tcc in ["Documents", "Desktop", "Library"] {
            try FileManager.default.createDirectory(atPath: "\(home)/\(tcc)", withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(atPath: "\(home)/code", withIntermediateDirectories: true)
        try "n".write(toFile: "\(home)/notes.txt", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: home)
        let names = tree.children?.map(\.displayName).sorted() ?? []
        #expect(names == ["code", "notes.txt"])
    }

    @Test("walks a TCC path when it is the explicit root")
    func walk_allowsTCCPathAsExplicitRoot() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let documents = "\(home)/Documents"
        try FileManager.default.createDirectory(atPath: "\(documents)/proj", withIntermediateDirectories: true)
        try "x".write(toFile: "\(documents)/proj/main.swift", atomically: true, encoding: .utf8)

        // Documents is the chosen root → must be walked, not skipped.
        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: documents)
        #expect(tree.children?.map(\.displayName) == ["proj"])
    }

    @Test("skips a symlink resolving to a TCC path")
    func walk_skipsSymlinkedTCCChild() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }

        try FileManager.default.createDirectory(atPath: "\(home)/Documents", withIntermediateDirectories: true)
        let work = "\(home)/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try "x".write(toFile: "\(work)/keep.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: "\(work)/docs_link", withDestinationPath: "\(home)/Documents")

        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: work)
        let names = tree.children?.map(\.displayName).sorted() ?? []
        #expect(names == ["keep.txt"])
    }

    // MARK: - Async loader (Issue #2 Prong C)

    @Test("loadAsync does not block its caller's actor")
    @MainActor
    func loadAsync_doesNotBlockCaller() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        for i in 0..<200 {
            try "x".write(toFile: "\(tmp)/file-\(i).txt", atomically: true, encoding: .utf8)
        }

        var sentinelTicks = 0
        let sentinel = Task { @MainActor in
            // Run 5 ticks of 10ms each on MainActor; if MainActor is blocked
            // by the loader, the ticks won't fire.
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 10_000_000)
                sentinelTicks += 1
            }
        }

        _ = try await WorkspaceLoader().loadAsync(rootPath: tmp)

        try await sentinel.value
        #expect(sentinelTicks >= 4)  // allow 1 jitter slot
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
