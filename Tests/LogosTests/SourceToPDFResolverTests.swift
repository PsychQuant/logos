import Testing
import Foundation
@testable import Logos

@Suite("SourceToPDFResolver", .serialized)
struct SourceToPDFResolverTests {

    @Test("tex default uses latexmk")
    func texDefault() {
        let r = SourceToPDFResolver()
        let result = r.resolve(sourcePath: "/work/notes.tex", config: nil)
        #expect(result?.command.starts(with: "latexmk") == true)
        #expect(result?.pdfPath == "/work/notes.pdf")
        #expect(result?.workingDirectory == "/work")
    }

    @Test("md default uses pandoc")
    func mdDefault() {
        let r = SourceToPDFResolver()
        let result = r.resolve(sourcePath: "/work/draft.md", config: nil)
        #expect(result?.command.contains("pandoc") == true)
        #expect(result?.pdfPath == "/work/draft.pdf")
    }

    @Test("unknown extension returns nil")
    func unknownExt() {
        let r = SourceToPDFResolver()
        let result = r.resolve(sourcePath: "/work/notes.txt", config: nil)
        #expect(result == nil)
    }

    @Test("config override wins over default")
    func configOverrides() {
        let cfg = WorkspaceConfig(builds: [
            .init(sourceGlob: "*.tex", command: "make notes.pdf", pdfPath: "notes.pdf")
        ])
        let r = SourceToPDFResolver()
        let result = r.resolve(sourcePath: "/work/notes.tex", config: cfg)
        #expect(result?.command == "make notes.pdf")
    }
}
