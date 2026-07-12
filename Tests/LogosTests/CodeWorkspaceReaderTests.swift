import Testing
import Foundation
@testable import Logos

@Suite("CodeWorkspaceReader")
struct CodeWorkspaceReaderTests {

    // Build an isolated temp tree and return its base path. Caller cleans up.
    private func makeBase() throws -> String {
        let base = NSTemporaryDirectory() + "logos-cwr-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func writeWorkspaceFile(_ path: String, json: String) throws {
        try json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("resolves relative-to-file and absolute folders, in order")
    func resolvesInOrder() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        // base/proj/{project.code-workspace, app/}, base/shared-lib/ (via ../), base/abs/
        try mkdir("\(base)/proj/app")
        try mkdir("\(base)/shared-lib")
        try mkdir("\(base)/abs")
        let wsFile = "\(base)/proj/project.code-workspace"
        try writeWorkspaceFile(wsFile, json: """
        { "folders": [ { "path": "app" }, { "path": "../shared-lib", "name": "Shared" }, { "path": "\(base)/abs" } ] }
        """)

        let ws = try CodeWorkspaceReader.read(codeWorkspaceFile: wsFile)

        #expect(ws.source == .codeWorkspaceFile(path: wsFile))
        #expect(ws.folders.count == 3)
        #expect(ws.folders[0].path == "\(base)/proj/app")     // relative → file dir
        #expect(ws.folders[1].path == "\(base)/shared-lib")   // ../ resolved
        #expect(ws.folders[1].name == "Shared")
        #expect(ws.folders[2].path == "\(base)/abs")          // absolute passthrough
        #expect(ws.firstFolder.path == "\(base)/proj/app")    // first folder = cwd
    }

    @Test("drops a folder that does not exist on disk, survivors remain in order")
    func dropsMissing() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try mkdir("\(base)/proj/app")
        let wsFile = "\(base)/proj/project.code-workspace"
        try writeWorkspaceFile(wsFile, json: """
        { "folders": [ { "path": "app" }, { "path": "nope" } ] }
        """)

        let ws = try CodeWorkspaceReader.read(codeWorkspaceFile: wsFile)
        #expect(ws.folders.count == 1)
        #expect(ws.folders[0].path == "\(base)/proj/app")
    }

    @Test("zero surviving folders throws noSurvivingFolders")
    func zeroSurvivors() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try mkdir("\(base)/proj")
        let wsFile = "\(base)/proj/project.code-workspace"
        try writeWorkspaceFile(wsFile, json: """
        { "folders": [ { "path": "gone" }, { "path": "also-gone" } ] }
        """)

        #expect(throws: CodeWorkspaceReader.ReadError.noSurvivingFolders) {
            _ = try CodeWorkspaceReader.read(codeWorkspaceFile: wsFile)
        }
    }

    @Test("malformed JSON throws malformed")
    func malformed() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try mkdir("\(base)/proj")
        let wsFile = "\(base)/proj/project.code-workspace"
        try writeWorkspaceFile(wsFile, json: "{ not valid json ")

        #expect(throws: CodeWorkspaceReader.ReadError.malformed) {
            _ = try CodeWorkspaceReader.read(codeWorkspaceFile: wsFile)
        }
    }

    @Test("adHoc normalizes a single directory to a one-root workspace")
    func adHocNormalizes() {
        let ws = CodeWorkspaceReader.adHoc(folder: "/tmp/proj")
        #expect(ws.folders.count == 1)
        #expect(ws.firstFolder.path == "/tmp/proj")
        #expect(ws.source == .adHocFolder)
    }

    @Test("isCodeWorkspaceFile detects the extension")
    func detectsExtension() {
        #expect(CodeWorkspaceReader.isCodeWorkspaceFile("/x/project.code-workspace") == true)
        #expect(CodeWorkspaceReader.isCodeWorkspaceFile("/x/some-folder") == false)
        #expect(CodeWorkspaceReader.isCodeWorkspaceFile("/x/file.txt") == false)
    }
}
