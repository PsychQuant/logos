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

    @ObservationIgnored private static let log = Logger(subsystem: "app.getlogos.logos", category: "workspace")

    public private(set) var rootNode: FileNode?
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

    public func openWorkspace(at path: String) throws {
        rootNode = try loader.load(rootPath: path)
        persistence.saveLastPath(path)
    }

    /// Async opener — runs filesystem walk off the main thread, sets
    /// `isLoading` for the duration. A second call cancels the first, so
    /// only the most recent invocation's tree reaches `rootNode`.
    public func openWorkspaceAsync(at path: String) async {
        currentLoadTask?.cancel()
        let task = Task { @MainActor [loader, persistence] in
            await Self.performLoad(
                loader: loader,
                persistence: persistence,
                path: path,
                model: self
            )
        }
        currentLoadTask = task
        await task.value
    }

    private static func performLoad(
        loader: any WorkspaceLoading,
        persistence: WorkspacePersistence,
        path: String,
        model: WorkspaceModel
    ) async {
        model.loadEpoch += 1
        let myEpoch = model.loadEpoch
        model.isLoading = true
        // Only the latest load clears the spinner — a stale load's defer must
        // not flip `isLoading` off while a newer load is mid-walk (#4).
        defer { if model.loadEpoch == myEpoch { model.isLoading = false } }
        do {
            let node = try await loader.loadAsync(rootPath: path)
            guard !Task.isCancelled else { return }
            model.rootNode = node
            model.lastError = nil          // healthy load clears any prior error (#9)
            persistence.saveLastPath(path)
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
            // persisted path only when it's definitively stale (not transient).
            let loadError = WorkspaceLoadError(from: error)
            model.lastError = loadError
            // Log the classification only — never the raw path / underlying error,
            // which carry the username + project names. Forcing `.public` on those
            // would un-redact PII in sysdiagnose / Console exports (verify finding).
            log.error("workspace load failed: \(String(describing: loadError), privacy: .public)")
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
