import Foundation
import Observation
import os

@Observable
@MainActor
public final class WorkspaceModel {

    @ObservationIgnored private let loader: any WorkspaceLoading
    @ObservationIgnored private let persistence: WorkspacePersistence
    @ObservationIgnored private var currentLoadTask: Task<Void, Never>?
    /// Monotonic per-load token. Guards the `isLoading` defer so a stale load's
    /// exit doesn't flip the spinner off while a newer load is in flight (#4).
    @ObservationIgnored private var loadEpoch: Int = 0

    /// The workspace's root folders — one `FileNode` per `Workspace.Folder`, in order (#96).
    /// A single-folder (ad-hoc) open yields exactly one root; a `.code-workspace` open yields
    /// one per surviving folder. Empty when no workspace is open.
    public private(set) var roots: [FileNode] = []

    /// The primary root — the first folder, which owns the session `cwd` and the preview
    /// build config. Derived from `roots` (not a second source of truth). Use `roots` for the
    /// full multi-root set (the sidebar); use `rootNode` only for genuinely primary-root
    /// concerns (launch check, PDF/preview config), never to enumerate the workspace.
    public var rootNode: FileNode? { roots.first }

    public private(set) var openTabs: [OpenFileTab] = []
    public private(set) var activeTab: OpenFileTab?
    public private(set) var showHidden: Bool = false
    public private(set) var isLoading: Bool = false
    /// Surfaced load failure for the UI banner (#9). `nil` while healthy;
    /// cleared on the next successful load or via `clearError()`.
    public private(set) var lastError: WorkspaceLoadError?

    public init(
        loader: any WorkspaceLoading = WorkspaceLoader(),
        persistence: WorkspacePersistence = WorkspacePersistence()
    ) {
        self.loader = loader
        self.persistence = persistence
    }

    /// The workspace-path persistence this model reads/writes. Exposed so the
    /// launch path (`MainScene`) shares this single instance instead of
    /// constructing its own — one source of truth (#11).
    public var workspacePersistence: WorkspacePersistence { persistence }

    /// Sync opener. `locator` is a workspace locator: a `.code-workspace` file path or a
    /// plain folder path (#96). Resolves the locator to a `Workspace`, walks each folder,
    /// and persists the locator.
    public func openWorkspace(at locator: String) throws {
        let workspace = try Self.resolveWorkspace(locator: locator)
        roots = try workspace.folders.map { try loader.load(rootPath: $0.path) }
        persistence.saveLastPath(locator)
    }

    /// Async opener — runs the locator resolution + filesystem walk off the main thread,
    /// sets `isLoading` for the duration. A second call cancels the first, so only the most
    /// recent invocation's roots reach `roots`. `locator` is a `.code-workspace` file path
    /// or a plain folder path (#96).
    public func openWorkspaceAsync(at locator: String) async {
        currentLoadTask?.cancel()
        let task = Task { @MainActor [loader, persistence] in
            await Self.performLoad(
                loader: loader,
                persistence: persistence,
                locator: locator,
                model: self
            )
        }
        currentLoadTask = task
        await task.value
    }

    /// Resolve a workspace locator to a `Workspace`: a `.code-workspace` file is parsed
    /// (multi-root, read-only), any other locator is a one-root ad-hoc folder (#96).
    private static func resolveWorkspace(locator: String) throws -> Workspace {
        if CodeWorkspaceReader.isCodeWorkspaceFile(locator) {
            return try CodeWorkspaceReader.read(codeWorkspaceFile: locator)
        }
        return CodeWorkspaceReader.adHoc(folder: locator)
    }

    private static func performLoad(
        loader: any WorkspaceLoading,
        persistence: WorkspacePersistence,
        locator: String,
        model: WorkspaceModel
    ) async {
        model.loadEpoch += 1
        let myEpoch = model.loadEpoch
        model.isLoading = true
        // Only the latest load clears the spinner — a stale load's defer must
        // not flip `isLoading` off while a newer load is mid-walk (#4).
        defer { if model.loadEpoch == myEpoch { model.isLoading = false } }
        do {
            // Resolve the locator (a `.code-workspace` read is small file I/O; kept off the
            // main actor here) then walk each folder into a root tree, in folder order (#96).
            let workspace = try resolveWorkspace(locator: locator)
            var loaded: [FileNode] = []
            for folder in workspace.folders {
                loaded.append(try await loader.loadAsync(rootPath: folder.path))
            }
            guard !Task.isCancelled else { return }
            model.roots = loaded
            model.lastError = nil          // healthy load clears any prior error (#9)
            persistence.saveLastPath(locator)
            // Success lifecycle marker (#22 follow-up): complements the failure-path
            // .error below. Root count is non-sensitive (public); the locator / folder
            // paths are never logged (they carry the username + project names).
            Log.workspace.notice("workspace load succeeded — roots=\(loaded.count, privacy: .public)")
        } catch is CancellationError {
            // Superseded by a newer load — not a failure, surface nothing (#4/#9).
            return
        } catch {
            // A superseded (cancelled) load must NOT clobber the winner's state:
            // without this guard a stale failing load could paint a phantom error
            // banner over a newer successful load and `persistence.clear()` could
            // wipe the path the winner just saved (verify DA finding). Symmetric
            // with the `!Task.isCancelled` guard on the success branch above.
            guard !Task.isCancelled else { return }
            // Surface the failure instead of swallowing it (#9). Clear the
            // persisted locator only when it's definitively stale (not transient).
            let loadError = WorkspaceLoadError(from: error)
            model.lastError = loadError
            // Log the classification only — never the raw locator / underlying error,
            // which carry the username + project names. Forcing `.public` on those
            // would un-redact PII in sysdiagnose / Console exports (verify finding).
            Log.workspace.error("workspace load failed: \(String(describing: loadError), privacy: .public)")
            if loadError.isStale {
                persistence.clear()
            }
        }
    }

    /// Dismiss the current load-error banner (#9).
    public func clearError() {
        lastError = nil
    }

    public func openFile(at path: String) {
        if let existing = openTabs.first(where: { $0.path == path }) {
            activeTab = existing
            return
        }
        let tab = OpenFileTab(path: path)
        openTabs.append(tab)
        activeTab = tab
    }

    public func closeTab(path: String) {
        guard let idx = openTabs.firstIndex(where: { $0.path == path }) else { return }
        openTabs.remove(at: idx)
        if activeTab?.path == path {
            activeTab = openTabs.last
        }
    }

    public func setActive(path: String) {
        guard let tab = openTabs.first(where: { $0.path == path }) else { return }
        activeTab = tab
    }

    public func toggleHidden() {
        showHidden.toggle()
    }
}
