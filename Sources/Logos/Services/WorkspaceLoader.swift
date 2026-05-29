import Foundation

public struct WorkspaceLoader: Sendable {

    static let skipNames: Set<String> = [
        ".git", ".build", ".swiftpm", ".DS_Store", "node_modules",
        "__pycache__", ".venv", "venv", ".pytest_cache", ".idea",
        ".vscode", ".superpowers"
    ]

    /// Pure-system roots blocked at **any depth** — `p == X` or `p.hasPrefix(X + "/")`.
    /// These never contain user workspaces. Catches firmlinks (`/usr/local`, not a
    /// symlink so left unresolved, caught by `/usr`) and `/opt/homebrew`. Never
    /// user content — dropped, not surfaced (Issue #6).
    static let prefixBlockPaths: [String] = [
        "/System", "/Library", "/usr", "/bin", "/sbin",
        "/dev", "/cores", "/Network", "/opt"
    ]

    /// Blocked **only as an exact match** — the path itself is refused, but
    /// descending into a chosen path *beneath* it is allowed. Two reasons a path
    /// belongs here rather than prefix-block (Issue #6 D1):
    ///   - `/`, `/Volumes`: a user may legitimately open `/Volumes/MyDrive/code`.
    ///   - `/private` (+ resolved `/private/var`, `/private/tmp`, `/private/etc`):
    ///     `/private` holds both system dirs AND the per-user temp tree
    ///     (`/private/var/folders/…`). Exact-blocking the system dirs + their
    ///     canonical-resolved forms catches a symlink→`/var` (which resolves to
    ///     `/private/var`) while still allowing scratch/temp workspaces. Prefix-
    ///     blocking `/private` would refuse every temp directory.
    static let exactBlockPaths: Set<String> = [
        "/", "/Volumes", "/private", "/private/var", "/private/tmp", "/private/etc"
    ]

    /// Bundle/package extensions that are TCC-protected or opaque app data —
    /// treated as protected leaves at any depth (Issue #13).
    static let tccPackageExtensions: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary"]

    /// First-level home children that are TCC-protected or pure app-data.
    /// Walking into these during a recursive descent triggers a modal macOS
    /// consent dialog per directory (Issue #7). Skipped only as *children* —
    /// see `tccSkipPaths` and the child filter in `walk`.
    static let userRelativeTCCNames: Set<String> = [
        "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies",
        "Library", ".Trash"
    ]

    public let maxDepth: Int
    public let maxFiles: Int

    /// Home directory used to derive the user-relative TCC skip set. Injectable
    /// so tests can substitute a temp dir without touching the real home.
    public let homeDirectory: String

    /// Canonical, depth-1 TCC-protected paths under `homeDirectory`. Computed
    /// once at init (canonicalized so the comparison matches the resolved child
    /// path the walk computes — /var → /private/var, symlinked home, etc.).
    /// Empty when `homeDirectory` is degenerate (see `init`).
    private let tccSkipPaths: Set<String>

    /// Canonical `~/Library`, used for **any-depth** subtree matching so opening
    /// `~/Library` directly as a root doesn't cascade into `~/Library/Mail` etc.
    /// (Issue #13). `nil` for a degenerate home.
    private let homeLibrary: String?

    public init(maxDepth: Int = 10, maxFiles: Int = 50_000, homeDirectory: String = NSHomeDirectory()) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.homeDirectory = homeDirectory
        // Degenerate home (`""` / `"/"`) → no reliable TCC paths; disable TCC
        // filtering rather than poisoning the set with `/Documents` etc. (#13).
        if homeDirectory.isEmpty || homeDirectory == "/" {
            self.tccSkipPaths = []
            self.homeLibrary = nil
        } else {
            self.tccSkipPaths = Set(Self.userRelativeTCCNames.map {
                Self.canonical("\(homeDirectory)/\($0)")
            })
            self.homeLibrary = Self.canonical("\(homeDirectory)/Library")
        }
    }

    public func load(rootPath: String) throws -> FileNode {
        let canonical = Self.canonical(rootPath)
        if Self.isSystemPath(canonical) {
            throw LoaderError.refusedSystemPath(canonical)
        }
        // NOTE: the root is intentionally NOT checked against `isTCCPath` —
        // opening e.g. `~/Documents` directly should still walk (one expected
        // prompt for the user-chosen folder). TCC filtering applies to children.
        var counter = 0
        return try walk(path: rootPath, depth: 1, counter: &counter)
    }

    /// True if `canonical` is a system path that must never be walked into.
    /// Two classes: prefix-block (any depth) + exact-block (root only). (#6)
    static func isSystemPath(_ canonical: String) -> Bool {
        if exactBlockPaths.contains(canonical) { return true }
        return prefixBlockPaths.contains { canonical == $0 || canonical.hasPrefix($0 + "/") }
    }

    /// True if `canonical` is a TCC-protected path whose contents we must not
    /// enumerate (would trigger a macOS consent dialog). Matches the depth-1
    /// home set, the whole `~/Library` subtree (any depth), and known TCC
    /// package extensions. (#13)
    func isTCCPath(_ canonical: String) -> Bool {
        if tccSkipPaths.contains(canonical) { return true }
        if let lib = homeLibrary, canonical == lib || canonical.hasPrefix(lib + "/") { return true }
        let ext = (canonical as NSString).pathExtension.lowercased()
        return Self.tccPackageExtensions.contains(ext)
    }

    /// Off-main-actor variant — wraps sync `load` in a detached Task so callers
    /// on `MainActor` don't block the UI thread during recursive walks.
    public func loadAsync(rootPath: String) async throws -> FileNode {
        let loader = self
        return try await Task.detached(priority: .userInitiated) {
            try loader.load(rootPath: rootPath)
        }.value
    }

    /// Canonical absolute path: resolves symlinks, collapses `//`, resolves
    /// `.`/`..`. One canonical form used by the root check, the child filter,
    /// and the TCC skip-set init so all comparisons are apples-to-apples (#6).
    static func canonical(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A child entry with its expensive lookups (canonical path + isDirectory)
    /// computed exactly once — kept off the recursion hot path.
    private struct WalkEntry {
        let name: String
        let path: String
        let canonical: String
        let isDir: Bool
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

        // Graceful catch (#13): a permission-denied directory becomes an opaque
        // protected leaf rather than aborting the walk. Belt-and-suspenders for
        // TCC paths not in the static set that prompt-then-deny.
        let rawEntries: [String]
        do {
            rawEntries = try fm.contentsOfDirectory(atPath: path)
        } catch {
            return FileNode(path: path, kind: .directory, children: nil, isProtected: true)
        }

        let entries: [WalkEntry] = rawEntries
            .filter { !Self.skipNames.contains($0) }
            .map { name -> WalkEntry in
                let childPath = "\(path)/\(name)"
                var d: ObjCBool = false
                fm.fileExists(atPath: childPath, isDirectory: &d)
                return WalkEntry(name: name, path: childPath,
                                 canonical: Self.canonical(childPath), isDir: d.boolValue)
            }
            // System paths are never user content → dropped entirely (#6).
            .filter { !Self.isSystemPath($0.canonical) }
            .sorted { lhs, rhs in
                if lhs.isDir != rhs.isDir { return lhs.isDir }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        var children: [FileNode] = []
        for entry in entries {
            if counter >= maxFiles {
                throw LoaderError.tooManyFiles(found: counter, cap: maxFiles)
            }
            counter += 1
            // TCC paths are SURFACED as opaque protected leaves (#13, D3): the
            // user sees the dir but we never descend → no consent-dialog cascade,
            // no silent omission.
            if isTCCPath(entry.canonical) {
                children.append(FileNode(path: entry.path, kind: .directory,
                                         children: nil, isProtected: true))
                continue
            }
            do {
                children.append(try walk(path: entry.path, depth: depth + 1, counter: &counter))
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
