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

    private func writeSettings(_ json: String, into dir: String) throws {
        try FileManager.default.createDirectory(atPath: "\(dir)/.vscode", withIntermediateDirectories: true)
        try json.write(toFile: "\(dir)/.vscode/settings.json", atomically: true, encoding: .utf8)
    }

    @Test("files.exclude honors only the patterns whose value is true (#97 Slice 1)")
    func filesExcludeEnabledOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeSettings(
            #"{ "editor.fontSize": 14, "files.exclude": { "**/.DS_Store": true, "dist": true, "keep": false } }"#,
            into: dir
        )

        let settings = VSCodeSettingsReader.read(folderPath: dir)
        #expect(settings.presentKeys.contains("editor.fontSize"))          // all keys still visible
        #expect(settings.filesExclude == ["**/.DS_Store", "dist"])          // sorted, true-only
        #expect(settings.honoredKeys == ["files.exclude"])                  // seam now honors a key
    }

    @Test("filesExcludeMap retains every present key (incl. false); filesExclude derives enabled-only")
    func filesExcludeMapRetainsPresentKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // dist:true enabled; keep:false present-but-disabled; n:1 present-but-disabled (integer, not bool)
        try writeSettings(#"{ "files.exclude": { "dist": true, "keep": false, "n": 1 } }"#, into: dir)

        let s = VSCodeSettingsReader.read(folderPath: dir)
        #expect(s.filesExcludeMap == ["dist": true, "keep": false, "n": false])  // all present; enabled = value===true
        #expect(s.filesExclude == ["dist"])                                       // derived: enabled-only, sorted
    }

    @Test("resolvedExcludes: folder merges over workspace, folder wins incl. false-override")
    func resolvedExcludesMerge() {
        // union + folder-wins: folder's false un-hides the workspace-hidden **/*.log
        #expect(VSCodeSettingsReader.resolvedExcludes(
            workspace: ["dist": true, "**/*.log": true],
            folder: ["**/*.log": false, "build": true]) == ["build", "dist"])
        // folder empty → workspace applies unchanged (sorted: "*" < "d")
        #expect(VSCodeSettingsReader.resolvedExcludes(
            workspace: ["dist": true, "**/*.log": true], folder: [:]) == ["**/*.log", "dist"])
        // workspace empty → folder applies (its false key drops out)
        #expect(VSCodeSettingsReader.resolvedExcludes(
            workspace: [:], folder: ["out": true, "keep": false]) == ["out"])
        // both empty
        #expect(VSCodeSettingsReader.resolvedExcludes(workspace: [:], folder: [:]) == [])
    }

    @Test("an empty or key-less files.exclude honors nothing")
    func filesExcludeEmptyHonorsNothing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeSettings(#"{ "editor.fontSize": 14, "files.exclude": {} }"#, into: dir)

        let settings = VSCodeSettingsReader.read(folderPath: dir)
        #expect(settings.presentKeys.contains("editor.fontSize"))
        #expect(settings.filesExclude.isEmpty)
        #expect(settings.honoredKeys.isEmpty)
    }

    @Test("a conditional (when-object) files.exclude value is not treated as enabled")
    func filesExcludeConditionalIgnored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // VS Code allows `{ "when": "$(basename).ts" }` — not a bare `true`, so conservatively unhonored.
        try writeSettings(#"{ "files.exclude": { "**/*.js": { "when": "$(basename).ts" }, "out": true } }"#, into: dir)

        let settings = VSCodeSettingsReader.read(folderPath: dir)
        #expect(settings.filesExclude == ["out"])
    }

    @Test("an integer files.exclude value is not treated as enabled (only literal true)")
    func filesExcludeIntegerNotEnabled() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // JSON `1` bridges to `Bool` true via NSNumber — must NOT count as enabled; only `true` does.
        try writeSettings(#"{ "files.exclude": { "a": 1, "b": true, "c": 0 } }"#, into: dir)

        let settings = VSCodeSettingsReader.read(folderPath: dir)
        #expect(settings.filesExclude == ["b"])   // 1 and 0 are numbers, not booleans; only b:true honored
    }

    @Test("absent .vscode/settings.json yields the neutral seam result")
    func absentNeutral() {
        let settings = VSCodeSettingsReader.read(folderPath: "/nonexistent-\(UUID().uuidString)")
        #expect(settings == .neutral)
        #expect(settings.honoredKeys.isEmpty)
        #expect(settings.filesExclude.isEmpty)
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
