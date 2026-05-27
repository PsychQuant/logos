import Testing
import Foundation
@testable import Logos

@Suite("WorkspaceModel", .serialized)
@MainActor
struct WorkspaceModelTests {

    @Test("starts without workspace")
    func noWorkspace() {
        let m = WorkspaceModel()
        #expect(m.rootNode == nil)
        #expect(m.openTabs.isEmpty)
        #expect(m.activeTab == nil)
    }

    @Test("openWorkspace sets root")
    func openWorkspace() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let m = WorkspaceModel()
        try m.openWorkspace(at: tmp)
        #expect(m.rootNode?.path == tmp)
        #expect(m.rootNode?.children?.first?.displayName == "a.txt")
    }

    @Test("openFile adds tab and activates")
    func openFile() {
        let m = WorkspaceModel()
        m.openFile(at: "/tmp/x.swift")
        #expect(m.openTabs.count == 1)
        #expect(m.activeTab?.path == "/tmp/x.swift")
    }

    @Test("openFile twice doesn't duplicate")
    func openFileNoDuplicate() {
        let m = WorkspaceModel()
        m.openFile(at: "/tmp/x.swift")
        m.openFile(at: "/tmp/x.swift")
        #expect(m.openTabs.count == 1)
    }

    @Test("closeTab removes and reactivates next")
    func closeTab() {
        let m = WorkspaceModel()
        m.openFile(at: "/tmp/a")
        m.openFile(at: "/tmp/b")
        m.closeTab(path: "/tmp/b")
        #expect(m.openTabs.count == 1)
        #expect(m.activeTab?.path == "/tmp/a")
    }

    @Test("toggleHidden updates flag")
    func toggleHidden() {
        let m = WorkspaceModel()
        #expect(m.showHidden == false)
        m.toggleHidden()
        #expect(m.showHidden == true)
    }

    // MARK: - Async opener + isLoading (Issue #2 Prong C)

    @Test("openWorkspaceAsync — post-conditions: isLoading clears, rootNode set")
    func openWorkspaceAsync_happyPath() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let m = WorkspaceModel()
        #expect(m.isLoading == false)

        await m.openWorkspaceAsync(at: tmp)

        #expect(m.isLoading == false)
        #expect(m.rootNode?.path == tmp)
    }

    @Test("openWorkspaceAsync — isLoading observable while detached walk runs")
    func openWorkspaceAsync_observableIsLoading() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // Enough files that the detached walk yields enough time slices for
        // the MainActor probe loop to observe `isLoading == true`.
        for i in 0..<2000 {
            try "x".write(toFile: "\(tmp)/file-\(i).txt", atomically: true, encoding: .utf8)
        }

        let m = WorkspaceModel()
        async let loadAwait: Void = m.openWorkspaceAsync(at: tmp)

        var sawLoading = false
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 1_000_000)
            if m.isLoading { sawLoading = true; break }
        }
        await loadAwait

        #expect(sawLoading == true)
        #expect(m.isLoading == false)
    }

    @Test("openWorkspaceAsync — sequential calls converge on last tree")
    func openWorkspaceAsync_sequential() async throws {
        let tmp1 = try makeTempDir()
        let tmp2 = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(atPath: tmp1)
            try? FileManager.default.removeItem(atPath: tmp2)
        }
        try "x".write(toFile: "\(tmp1)/a.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(tmp2)/b.txt", atomically: true, encoding: .utf8)

        let m = WorkspaceModel()
        await m.openWorkspaceAsync(at: tmp1)
        await m.openWorkspaceAsync(at: tmp2)

        #expect(m.rootNode?.path == tmp2)
        #expect(m.isLoading == false)
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-wm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
