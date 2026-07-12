import Testing
import Foundation
@testable import Logos

@Suite("VSCodeSettingsReader")
struct VSCodeSettingsReaderTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-vscode-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("parses present keys but honors zero of them (no behavior change in this change)")
    func honorsZeroKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: "\(dir)/.vscode", withIntermediateDirectories: true)
        try #"{ "editor.fontSize": 14, "files.exclude": {} }"#
            .write(toFile: "\(dir)/.vscode/settings.json", atomically: true, encoding: .utf8)

        let settings = VSCodeSettingsReader.read(folderPath: dir)
        #expect(settings.presentKeys.contains("editor.fontSize"))   // parsed
        #expect(settings.honoredKeys.isEmpty)                        // interpreted: none
    }

    @Test("absent .vscode/settings.json yields the neutral seam result")
    func absentNeutral() {
        let settings = VSCodeSettingsReader.read(folderPath: "/nonexistent-\(UUID().uuidString)")
        #expect(settings == .neutral)
        #expect(settings.honoredKeys.isEmpty)
    }

    @Test("a walked workspace tree omits the .vscode directory")
    func walkOmitsVscode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: "\(dir)/.vscode", withIntermediateDirectories: true)
        try "{}".write(toFile: "\(dir)/.vscode/settings.json", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(dir)/main.swift", atomically: true, encoding: .utf8)

        let root = try WorkspaceLoader().load(rootPath: dir)
        let names = (root.children ?? []).map(\.displayName)
        #expect(names.contains("main.swift"))
        #expect(!names.contains(".vscode"))
    }
}
