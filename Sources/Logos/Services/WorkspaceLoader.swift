import Foundation

/// Thread-safe cancellation flag bridging a parent `Task`'s cancellation into
/// the cancellation-orphaned `Task.detached` compute (Issue #4). `Task.detached`
/// has no parent-cancellation link, so `loadAsync` wires `withTaskCancellationHandler`
/// to flip this flag, which the sync `walk` polls cooperatively.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    init() {}

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Protocol seam over the workspace loader so `WorkspaceModel` can take an
/// injected, controllable test double (Issue #15). Covers BOTH the sync
/// `load` and the async `loadAsync` so the single seam serves the sync
/// `openWorkspace(at:)` path and the async `openWorkspaceAsync(at:)` path
/// without `WorkspaceModel` holding a concrete `WorkspaceLoader`. `Sendable`
/// because the conforming value is captured across the `[loader, persistence]`
/// boundary in `openWorkspaceAsync`.
public protocol WorkspaceLoading: Sendable {
    func load(rootPath: String, isCancelled: @escaping @Sendable () -> Bool) throws -> FileNode
    func loadAsync(rootPath: String) async throws -> FileNode
}

extension WorkspaceLoading {
    /// Default `isCancelled` so a stub need only implement the cancellable
    /// overload, and sync callers that don't cancel can omit the argument.
    public func load(rootPath: String) throws -> FileNode {
        try load(rootPath: rootPath, isCancelled: { false })
    }
}

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
    ///   - `/private`, `/var`, `/tmp`, `/etc`: these hold both system dirs AND
    ///     the per-user temp tree (`/var/folders/…`). Exact-blocking the system
    ///     dirs while allowing scratch/temp workspaces beneath them.
    ///
    /// IMPORTANT — these are stored in their **canonical** form (what
    /// `canonical(_:)` produces), because every comparison runs the input
    /// through `canonical()` first. On macOS `/var`,`/tmp`,`/etc` are symlinks
    /// to `/private/*`, and `resolvingSymlinksInPath()` collapses to the
    /// **shortest** equivalent — so `canonical("/private/var") == "/var"`, NOT
    /// the reverse. A symlink→`/var` therefore canonicalizes to `/var` and is
    /// caught here; storing `/private/var` instead would be dead code that the
    /// canonicalizer never produces (regression caught in #6/#13 verify).
    static let exactBlockPaths: Set<String> = [
        "/", "/Volumes", "/private", "/var", "/tmp", "/etc", "/Users"
    ]
    // `/Users` is exact-blocked (not prefix): opening the all-users container as
    // a workspace walks every user's home tree (#2's class of bug at a different
    // root), but `/Users/<name>/proj` must still be openable — so exact, not
    // prefix. Surfaced by #8 verify (reachable via `--workspace /Users` or a
    // direct-binary launch with cwd there).

    /// System subtrees under `/var` that are never workspaces — blocked at **any
    /// depth** (`p == X` or `p.hasPrefix(X + "/")`) by `isSystemPath`. (Issue #14)
    ///
    /// `/var` itself is only exact-blocked (see `exactBlockPaths`) because the
    /// per-user temp tree `/var/folders/…` is a legitimate scratch-workspace
    /// location and must stay openable; a blanket `/var` prefix-block would close
    /// it. So rather than prefix-block `/var` with a `/var/folders` carve-out
    /// (the documented alternative in #14), this is an explicit allowlist-of-blocks:
    /// it is simpler to reason about, makes the per-subtree intent visible, and
    /// avoids accidentally blocking a future legitimate `/var` workspace. Net
    /// effect: `/var` stays exact-blocked, these listed subtrees become any-depth
    /// blocked, and `/var/folders/…` stays allowed.
    ///
    /// IMPORTANT — stored in their **canonical** (short `/var/…`) form, matching
    /// the `exactBlockPaths` invariant: every input runs through `canonical()`
    /// first, and on macOS `canonical("/private/var/db") == "/var/db"`, so the
    /// short form is the only one the canonicalizer ever produces.
    static let varSubtreeBlockPaths: [String] = [
        "/var/db", "/var/log", "/var/logs", "/var/root", "/var/vm",
        "/var/spool", "/var/run", "/var/mail", "/var/audit",
        "/var/backups", "/var/lib", "/var/empty"
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

    /// Maximum directory nesting walked, counting the root as depth 1
    /// (root = 1, its children = 2, …). Subtrees deeper than this are returned
    /// as opaque, un-expanded directory nodes rather than recursed into.
    public let maxDepth: Int

    /// Upper bound on the number of filesystem ENTRIES visited during a walk —
    /// directories plus files, and including entries that vanish mid-walk
    /// (missing-file races count against it). This is NOT a strict leaf-file
    /// count; the name is historical. Exceeding it fails fast with
    /// `LoaderError.tooManyFiles` to bound catastrophic inputs.
    public let maxFiles: Int

    /// Home directory used to derive the user-relative TCC skip set. Injectable
    /// so tests can substitute a temp dir without touching the real home.
    public let homeDirectory: String

    /// Canonical, depth-1 TCC-protected paths under `homeDirectory`. Computed
    /// once at init (canonicalized so the comparison matches the resolved child
    /// path the walk computes — /var → /private/var, symlinked home, etc.).
    /// Empty when `homeDirectory` is degenerate (see `init`).
    ///
    /// Cross-home note (#14, item 3): the no-cascade *pre-avoidance* guarantee
    /// (children are never even read, so no consent dialog fires) holds only for
    /// the injected `homeDirectory`. Opening ANOTHER user's home (e.g.
    /// `/Users/bob`) leaves bob's TCC dirs out of this set, so they are not
    /// pre-avoided; instead the walk's `contentsOfDirectory` graceful-catch
    /// backstop turns each into an opaque protected leaf — i.e. it degrades
    /// gracefully to one-prompt-then-opaque rather than cascading. Owner-relative
    /// TCC derivation (stat/owner lookups per directory) is intentionally out of
    /// scope here.
    private let tccSkipPaths: Set<String>

    /// Canonical `~/Library`, used for **any-depth** subtree matching so opening
    /// `~/Library` directly as a root doesn't cascade into `~/Library/Mail` etc.
    /// (Issue #13). `nil` for a degenerate home.
    private let homeLibrary: String?

    /// Per-directory test seam (Issue #15). Invoked once near the top of every
    /// `walk` frame (after the entry is confirmed a readable, non-symlink
    /// directory and before its contents are listed), keyed by the frame's
    /// canonical path. Defaults to a no-op so production behavior is unchanged.
    ///
    /// Why this seam exists: the per-child generic `catch { continue }` in
    /// `walk` (the branch that drops one bad child while keeping its siblings)
    /// is unreachable from a real filesystem fixture — a permission-denied
    /// child is converted to an opaque protected leaf by that child frame's own
    /// `contentsOfDirectory` graceful-catch BEFORE the parent's per-child catch
    /// is reached (Issue #13 path). To deterministically exercise the per-child
    /// generic catch, a test injects a hook that throws a generic
    /// (non-`LoaderError`, non-`CancellationError`) error for ONE child path:
    /// the throw originates inside that child's own frame, escapes its frame
    /// (it is NOT inside the `contentsOfDirectory` do/catch), and lands in the
    /// parent's per-child generic catch, dropping just that child.
    private let childWalkHook: @Sendable (String) throws -> Void

    public init(maxDepth: Int = 10, maxFiles: Int = 50_000, homeDirectory: String = NSHomeDirectory(),
                childWalkHook: @escaping @Sendable (String) throws -> Void = { _ in }) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.homeDirectory = homeDirectory
        self.childWalkHook = childWalkHook
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

    /// Synchronous walk. `isCancelled` is polled cooperatively so a caller can
    /// halt an in-flight walk's I/O (Issue #4); defaults to never-cancelled so
    /// existing sync callers are unaffected.
    public func load(rootPath: String, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> FileNode {
        let canonical = Self.canonical(rootPath)
        if Self.isSystemPath(canonical) {
            throw LoaderError.refusedSystemPath(canonical)
        }
        // NOTE: the root is intentionally NOT checked against `isTCCPath` —
        // opening e.g. `~/Documents` directly should still walk (one expected
        // prompt for the user-chosen folder). TCC filtering applies to children.
        var counter = 0
        return try walk(path: rootPath, depth: 1, counter: &counter, isCancelled: isCancelled)
    }

    /// True if `canonical` is a system path that must never be walked into.
    /// Three classes: prefix-block (any depth) + exact-block (root only, #6) +
    /// listed `/var` system subtrees (any depth, #14) — the last keeps `/var`
    /// exact-blocked while closing `/var/db`, `/var/log`, etc. at any depth,
    /// without closing the `/var/folders` per-user temp tree.
    static func isSystemPath(_ canonical: String) -> Bool {
        if exactBlockPaths.contains(canonical) { return true }
        if prefixBlockPaths.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) {
            return true
        }
        return varSubtreeBlockPaths.contains { canonical == $0 || canonical.hasPrefix($0 + "/") }
    }

    /// True if `canonical` is a TCC-protected path whose contents we must not
    /// enumerate (would trigger a macOS consent dialog). Matches the depth-1
    /// home set, the whole `~/Library` subtree (any depth), and **real** TCC
    /// package bundles (#13, #14). The cheap string checks run first; the
    /// structural package read (`looksLikeRealPackage`) runs last and only when
    /// the extension already matches.
    func isTCCPath(_ canonical: String) -> Bool {
        if tccSkipPaths.contains(canonical) { return true }
        if let lib = homeLibrary, canonical == lib || canonical.hasPrefix(lib + "/") { return true }
        let ext = (canonical as NSString).pathExtension.lowercased()
        // #14: lock only when BOTH the extension matches AND the directory has
        // the bundle's signature children — a plain user folder literally named
        // `Foo.photoslibrary` must walk normally, not be hidden as an opaque
        // leaf. `URLResourceValues.isPackageKey` is NOT a usable discriminator:
        // LaunchServices keys it off the registered extension and returns true
        // for a same-named plain dir too, so structural-content detection is the
        // only reliable signal.
        guard Self.tccPackageExtensions.contains(ext) else { return false }
        return Self.looksLikeRealPackage(path: canonical, ext: ext)
    }

    /// Structural check distinguishing a genuine TCC package bundle from a plain
    /// directory that merely shares the extension (#14). For each known package
    /// extension it looks for that bundle's signature child entries via a single
    /// `FileManager.contentsOfDirectory(atPath:)`. On a read error it defaults to
    /// `true` (fail-safe: a permission-denied real package must stay locked).
    ///
    /// COST NOTE: this directory read only ever runs on the protected-leaf path —
    /// `isTCCPath` calls it solely after the cheap `pathExtension` check already
    /// matched a TCC extension — so it adds nothing to the common non-package walk.
    private static func looksLikeRealPackage(path: String, ext: String) -> Bool {
        let markers: Set<String>
        switch ext {
        case "photoslibrary": markers = ["database", "originals", "Photos.sqlite"]
        case "musiclibrary":  markers = ["Library.musicdb"]
        case "tvlibrary":     markers = ["Library.tvdb"]
        default:              return true
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return true  // fail-safe: keep locking an unreadable (likely real) package
        }
        return !markers.isDisjoint(with: Set(entries))
    }

    /// Off-main-actor variant — wraps sync `load` in a detached Task so callers
    /// on `MainActor` don't block the UI thread during recursive walks. The
    /// detached task is cancellation-orphaned, so a `CancelFlag` bridges the
    /// awaiting task's cancellation into the walk via `withTaskCancellationHandler`
    /// (Issue #4): when the awaiting task is cancelled, `onCancel` flips the flag
    /// and the walk throws `CancellationError` at its next poll point.
    public func loadAsync(rootPath: String) async throws -> FileNode {
        let loader = self
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try loader.load(rootPath: rootPath, isCancelled: { flag.isCancelled })
            }.value
        } onCancel: {
            flag.cancel()
        }
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

    private func walk(path: String, depth: Int, counter: inout Int,
                      isCancelled: @escaping @Sendable () -> Bool) throws -> FileNode {
        // Cooperative cancellation poll (#4): halts an in-flight walk between
        // entries when the awaiting task is cancelled (rapid Cmd+O).
        if isCancelled() { throw CancellationError() }
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

        // Per-directory test seam (#15). Default no-op in production. A throw
        // here escapes this frame (it is OUTSIDE the contentsOfDirectory
        // do/catch below) and, for a non-root frame, lands in the parent's
        // per-child generic `catch { continue }`. Keyed by canonical path so a
        // test can target exactly one child.
        try childWalkHook(Self.canonical(path))

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
            if isCancelled() { throw CancellationError() }
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
            // Per-child error policy (#9): propagate the fatal ones
            // (`tooManyFiles`, `CancellationError`); skip everything else
            // (notFound, permission-denied, EIO) so one bad child doesn't abort
            // the whole load — restores #2's permissive walk.
            do {
                children.append(try walk(path: entry.path, depth: depth + 1, counter: &counter,
                                         isCancelled: isCancelled))
            } catch let e as LoaderError {
                if case .tooManyFiles = e { throw e }
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // permission denied / EIO / any other per-child error → skip child
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

// `WorkspaceLoader`'s existing `load(rootPath:isCancelled:)` and
// `loadAsync(rootPath:)` already match `WorkspaceLoading` exactly, so the
// conformance is empty — the protocol is purely a seam for injection (#15).
extension WorkspaceLoader: WorkspaceLoading {}
