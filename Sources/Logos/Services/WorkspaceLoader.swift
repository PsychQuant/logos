import Foundation

public struct WorkspaceLoader: Sendable {

    static let skipNames: Set<String> = [
        ".git", ".build", ".swiftpm", ".DS_Store", "node_modules",
        "__pycache__", ".venv", "venv", ".pytest_cache", ".idea",
        ".vscode", ".superpowers"
    ]

    static let absoluteSkipPaths: Set<String> = [
        "/", "/System", "/Library", "/private", "/usr", "/Volumes",
        "/dev", "/etc", "/var", "/bin", "/sbin", "/cores"
    ]

    public let maxDepth: Int
    public let maxFiles: Int

    public init(maxDepth: Int = 10, maxFiles: Int = 50_000) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
    }

    public func load(rootPath: String) throws -> FileNode {
        let normalized = Self.normalize(rootPath)
        if Self.absoluteSkipPaths.contains(normalized) {
            throw LoaderError.refusedSystemPath(normalized)
        }
        var counter = 0
        return try walk(path: rootPath, depth: 1, counter: &counter)
    }

    /// Off-main-actor variant — wraps sync `load` in a detached Task so callers
    /// on `MainActor` don't block the UI thread during recursive walks.
    public func loadAsync(rootPath: String) async throws -> FileNode {
        let loader = self
        return try await Task.detached(priority: .userInitiated) {
            try loader.load(rootPath: rootPath)
        }.value
    }

    static func normalize(_ p: String) -> String {
        if p.count > 1 && p.hasSuffix("/") {
            return String(p.dropLast())
        }
        return p
    }

    private func walk(path: String, depth: Int, counter: inout Int) throws -> FileNode {
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

        // Depth gate: return opaque directory (no expand) at max depth
        if depth >= maxDepth {
            return FileNode(path: path, kind: .directory, children: nil)
        }

        let entries = try fm.contentsOfDirectory(atPath: path)
            .filter { !Self.skipNames.contains($0) }
            .filter { name -> Bool in
                // Drop any child whose resolved real path matches a system root
                // (defense-in-depth: catches symlinks pointing at /Library etc.)
                let childPath = "\(path)/\(name)"
                let resolved = URL(fileURLWithPath: childPath).resolvingSymlinksInPath().path
                return !Self.absoluteSkipPaths.contains(Self.normalize(resolved))
            }
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

        var children: [FileNode] = []
        for name in entries {
            if counter >= maxFiles {
                throw LoaderError.tooManyFiles(found: counter, cap: maxFiles)
            }
            counter += 1
            let childPath = "\(path)/\(name)"
            do {
                children.append(try walk(path: childPath, depth: depth + 1, counter: &counter))
            } catch LoaderError.notFound {
                continue
            }
        }

        return FileNode(path: path, kind: .directory, children: children)
    }

    public enum LoaderError: Error, Equatable {
        case notFound(String)
        case refusedSystemPath(String)
        case tooManyFiles(found: Int, cap: Int)
    }
}
