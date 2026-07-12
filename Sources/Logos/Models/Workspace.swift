import Foundation

/// The definition of "what a workspace is" (#96): an ordered, **non-empty** set of
/// root folders plus provenance recording whether it was opened from a VS Code
/// `.code-workspace` file or from an ad-hoc single folder.
///
/// This is the alignment seam with the VS Code workspace protocol — a `.code-workspace`
/// file's `folders` array maps onto `folders` here, in order. `WorkspaceModel` derives
/// its `roots: [FileNode]` (one per folder) from a `Workspace`; the **first** folder is
/// the primary folder (the session `cwd` + preview-config owner).
///
/// The non-empty invariant is enforced by a failable `init` so `firstFolder` is a total
/// (non-optional) accessor — an empty workspace is not representable.
public struct Workspace: Equatable, Sendable {

    /// Where this workspace came from — kept so persistence can re-open it the same way
    /// and so future work can distinguish a real VS Code workspace from a plain folder.
    public enum Source: Equatable, Sendable {
        /// Opened by reading a VS Code `.code-workspace` file at this path.
        case codeWorkspaceFile(path: String)
        /// Opened as a plain directory (backward-compatible single-folder open).
        case adHocFolder
    }

    /// One root folder of the workspace. `path` is absolute and already resolved; `name`
    /// is the optional display override a `.code-workspace` entry may carry.
    public struct Folder: Equatable, Sendable {
        public let path: String
        public let name: String?

        public init(path: String, name: String? = nil) {
            self.path = path
            self.name = name
        }
    }

    public let source: Source
    /// Ordered, guaranteed non-empty (enforced by `init?`).
    public let folders: [Folder]

    /// Fails (returns nil) when `folders` is empty — the non-empty invariant. Callers that
    /// resolve a `.code-workspace` treat a nil here (no surviving folder) as a load error.
    public init?(source: Source, folders: [Folder]) {
        guard !folders.isEmpty else { return nil }
        self.source = source
        self.folders = folders
    }

    /// The primary folder — the session `cwd` and preview-config owner. Total (non-optional)
    /// because the non-empty invariant guarantees at least one folder exists.
    public var firstFolder: Folder { folders[0] }

    /// A one-root workspace over a plain directory (backward-compatible open). Never nil —
    /// a single folder always satisfies the non-empty invariant.
    public static func adHoc(folderPath: String) -> Workspace {
        // Force-unwrap is safe: exactly one folder → the invariant holds by construction.
        Workspace(source: .adHocFolder, folders: [Folder(path: folderPath)])!
    }
}
