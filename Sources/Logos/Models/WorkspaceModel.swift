import Foundation
import Observation

@Observable
@MainActor
public final class WorkspaceModel {

    @ObservationIgnored private let loader: WorkspaceLoader
    @ObservationIgnored private let persistence: WorkspacePersistence
    @ObservationIgnored private var currentLoadTask: Task<Void, Never>?

    public private(set) var rootNode: FileNode?
    public private(set) var openTabs: [OpenFileTab] = []
    public private(set) var activeTab: OpenFileTab?
    public private(set) var showHidden: Bool = false
    public private(set) var isLoading: Bool = false

    public init(
        loader: WorkspaceLoader = WorkspaceLoader(),
        persistence: WorkspacePersistence = WorkspacePersistence()
    ) {
        self.loader = loader
        self.persistence = persistence
    }

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
        loader: WorkspaceLoader,
        persistence: WorkspacePersistence,
        path: String,
        model: WorkspaceModel
    ) async {
        model.isLoading = true
        defer { model.isLoading = false }
        do {
            let node = try await loader.loadAsync(rootPath: path)
            guard !Task.isCancelled else { return }
            model.rootNode = node
            persistence.saveLastPath(path)
        } catch is CancellationError {
            return
        } catch {
            return
        }
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
