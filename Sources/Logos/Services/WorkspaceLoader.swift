import Foundation

public struct WorkspaceLoader {

    static let skipNames: Set<String> = [
        ".git", ".build", ".swiftpm", ".DS_Store", "node_modules",
        "__pycache__", ".venv", "venv", ".pytest_cache", ".idea",
        ".vscode", ".superpowers"
    ]

    public init() {}

    public func load(rootPath: String) throws -> FileNode {
        try walk(path: rootPath)
    }

    private func walk(path: String) throws -> FileNode {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw LoaderError.notFound(path)
        }
        guard isDir.boolValue else {
            return FileNode(path: path, kind: .file)
        }

        // Skip symlinks to avoid loops
        let attrs = try fm.attributesOfItem(atPath: path)
        if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            return FileNode(path: path, kind: .file)  // treat as file leaf
        }

        let children = try fm.contentsOfDirectory(atPath: path)
            .filter { !Self.skipNames.contains($0) }
            .sorted { lhs, rhs in
                let lhsPath = "\(path)/\(lhs)"
                let rhsPath = "\(path)/\(rhs)"
                var lhsDir: ObjCBool = false
                var rhsDir: ObjCBool = false
                fm.fileExists(atPath: lhsPath, isDirectory: &lhsDir)
                fm.fileExists(atPath: rhsPath, isDirectory: &rhsDir)
                if lhsDir.boolValue != rhsDir.boolValue {
                    return lhsDir.boolValue
                }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .compactMap { name -> FileNode? in
                try? walk(path: "\(path)/\(name)")
            }

        return FileNode(path: path, kind: .directory, children: children)
    }

    public enum LoaderError: Error, Equatable {
        case notFound(String)
    }
}
