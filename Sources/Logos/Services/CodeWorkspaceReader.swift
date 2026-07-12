import Foundation

/// Reads a VS Code `.code-workspace` file into a `Workspace` (#96) — the alignment seam
/// with the VS Code workspace protocol. **Read-only**: it parses but never writes a
/// `.code-workspace` file, and (like the rest of the workspace layer) never touches
/// credentials. Folder paths are resolved relative to the `.code-workspace` file's own
/// directory (absolute paths pass through); folders that don't exist on disk are dropped,
/// and a file with zero surviving folders or malformed JSON is a load error surfaced via
/// the existing `WorkspaceLoadError` banner path.
public enum CodeWorkspaceReader {

    public enum ReadError: Error, Equatable {
        /// The file could not be read (absent / permission).
        case unreadable
        /// The JSON did not parse, or was not a `{ "folders": [ … ] }` object.
        case malformed
        /// The `folders` array resolved to zero existing folders.
        case noSurvivingFolders
    }

    /// Whether a locator names a `.code-workspace` file (by extension, case-insensitive).
    /// Used to route a persisted/opened locator to `read` vs. an ad-hoc folder open.
    public static func isCodeWorkspaceFile(_ locator: String) -> Bool {
        locator.lowercased().hasSuffix(".code-workspace")
    }

    /// Parse a `.code-workspace` file → `Workspace`. Resolves each `folders[].path` against
    /// the file's directory (absolute passthrough), drops non-existent folders, and throws
    /// on zero survivors / malformed JSON / unreadable file.
    public static func read(
        codeWorkspaceFile path: String,
        fileManager: FileManager = .default
    ) throws -> Workspace {
        guard let data = fileManager.contents(atPath: path) else { throw ReadError.unreadable }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawFolders = obj["folders"] as? [[String: Any]]
        else { throw ReadError.malformed }

        let fileDir = (path as NSString).deletingLastPathComponent
        var resolved: [Workspace.Folder] = []
        for entry in rawFolders {
            guard let rel = entry["path"] as? String, !rel.isEmpty else { continue }
            let abs = resolveFolderPath(rel, relativeTo: fileDir)
            guard isExistingDirectory(abs, fileManager: fileManager) else { continue }  // drop missing
            resolved.append(Workspace.Folder(path: abs, name: entry["name"] as? String))
        }

        guard let workspace = Workspace(source: .codeWorkspaceFile(path: path), folders: resolved) else {
            throw ReadError.noSurvivingFolders
        }
        return workspace
    }

    /// Normalize a single directory into a one-root ad-hoc workspace (backward-compatible open).
    public static func adHoc(folder path: String) -> Workspace {
        Workspace.adHoc(folderPath: path)
    }

    // MARK: - Path resolution

    /// Resolve a `.code-workspace` folder entry: absolute passthrough, else relative to the
    /// file's directory. Uses `URL.standardized` — collapses `..`/`.` **without** resolving
    /// symlinks (so a `/var` → `/private/var` temp dir keeps its as-written path).
    private static func resolveFolderPath(_ rel: String, relativeTo dir: String) -> String {
        if rel.hasPrefix("/") {
            return URL(fileURLWithPath: rel).standardized.path
        }
        return URL(fileURLWithPath: dir).appendingPathComponent(rel).standardized.path
    }

    private static func isExistingDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
