import Testing
import Foundation
@testable import Logos

@Suite("WorkspaceConfig", .serialized)
struct WorkspaceConfigTests {

    @Test("parses minimal config")
    func parsesMinimal() throws {
        let yaml = """
        builds:
          - source: "*.tex"
            command: latexmk -pdf {source}
            preview: "{stem}.pdf"
        """
        let cfg = try WorkspaceConfig.parse(yamlString: yaml)
        #expect(cfg.builds.count == 1)
        #expect(cfg.builds[0].sourceGlob == "*.tex")
    }

    @Test("substitutes {source} and {stem}")
    func substitution() throws {
        let yaml = """
        builds:
          - source: "*.tex"
            command: latexmk -pdf {source}
            preview: "{stem}.pdf"
        """
        let cfg = try WorkspaceConfig.parse(yamlString: yaml)
        let resolved = cfg.builds[0].resolved(forSourceFile: "notes.tex")
        #expect(resolved.command == "latexmk -pdf notes.tex")
        #expect(resolved.pdfPath == "notes.pdf")
    }

    @Test("missing file returns nil from load(at:)")
    func missingFile() {
        let cfg = try? WorkspaceConfig.load(workspaceRoot: "/nonexistent")
        #expect(cfg == nil)
    }

    @Test("loads from actual workspace root")
    func loadsFromFile() throws {
        let dir = NSTemporaryDirectory() + "logos-wc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let yaml = """
        builds:
          - source: "*.md"
            command: pandoc {source}
            preview: out.pdf
        """
        try yaml.write(toFile: "\(dir)/.logosconfig.yaml", atomically: true, encoding: .utf8)

        let cfg = try WorkspaceConfig.load(workspaceRoot: dir)
        #expect(cfg?.builds.count == 1)
    }
}
