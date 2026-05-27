import Foundation
import Yams

public struct WorkspaceConfig: Sendable, Codable {

    public struct Build: Sendable, Codable {
        public let sourceGlob: String     // YAML key: source
        public let command: String
        public let pdfPath: String        // YAML key: preview

        enum CodingKeys: String, CodingKey {
            case sourceGlob = "source"
            case command
            case pdfPath = "preview"
        }

        public init(sourceGlob: String, command: String, pdfPath: String) {
            self.sourceGlob = sourceGlob
            self.command = command
            self.pdfPath = pdfPath
        }

        public struct Resolved: Sendable {
            public let command: String
            public let pdfPath: String
        }

        public func resolved(forSourceFile sourceFileName: String) -> Resolved {
            let stem = (sourceFileName as NSString).deletingPathExtension
            let cmdSub = command
                .replacingOccurrences(of: "{source}", with: sourceFileName)
                .replacingOccurrences(of: "{stem}", with: stem)
            let pdfSub = pdfPath
                .replacingOccurrences(of: "{source}", with: sourceFileName)
                .replacingOccurrences(of: "{stem}", with: stem)
            return Resolved(command: cmdSub, pdfPath: pdfSub)
        }
    }

    public let builds: [Build]

    public init(builds: [Build]) {
        self.builds = builds
    }

    public func matchingBuild(for sourcePath: String) -> Build? {
        let name = (sourcePath as NSString).lastPathComponent
        return builds.first { b in
            if b.sourceGlob.hasPrefix("*.") {
                return name.hasSuffix(String(b.sourceGlob.dropFirst(1)))
            }
            return name == b.sourceGlob
        }
    }

    public static func parse(yamlString: String) throws -> WorkspaceConfig {
        let decoder = YAMLDecoder()
        return try decoder.decode(WorkspaceConfig.self, from: yamlString)
    }

    public static func load(workspaceRoot: String) throws -> WorkspaceConfig? {
        let path = "\(workspaceRoot)/.logosconfig.yaml"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let yamlText = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(yamlString: yamlText)
    }
}
