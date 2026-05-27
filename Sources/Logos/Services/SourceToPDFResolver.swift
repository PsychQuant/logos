import Foundation

public struct SourceToPDFResolution: Sendable {
    public let command: String
    public let pdfPath: String
    public let workingDirectory: String
}

public struct SourceToPDFResolver {

    public init() {}

    public func resolve(sourcePath: String, config: WorkspaceConfig?) -> SourceToPDFResolution? {
        let url = URL(fileURLWithPath: sourcePath)
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent().path
        let ext = url.pathExtension.lowercased()

        // Config override first
        if let cfg = config, let match = cfg.matchingBuild(for: sourcePath) {
            let resolved = match.resolved(forSourceFile: url.lastPathComponent)
            return SourceToPDFResolution(
                command: resolved.command,
                pdfPath: "\(dir)/\(resolved.pdfPath)",
                workingDirectory: dir
            )
        }

        // Defaults
        switch ext {
        case "tex":
            return SourceToPDFResolution(
                command: "latexmk -pdf -interaction=nonstopmode -synctex=1 \(url.lastPathComponent)",
                pdfPath: "\(dir)/\(stem).pdf",
                workingDirectory: dir
            )
        case "md", "markdown":
            return SourceToPDFResolution(
                command: "pandoc -o \(stem).pdf \(url.lastPathComponent)",
                pdfPath: "\(dir)/\(stem).pdf",
                workingDirectory: dir
            )
        default:
            return nil
        }
    }
}
