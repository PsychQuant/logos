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

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-wm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
