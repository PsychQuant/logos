import Foundation
import Observation

@Observable
@MainActor
public final class WorkspaceModel {

    @ObservationIgnored private let loader: WorkspaceLoader

    public private(set) var rootNode: FileNode?
    public private(set) var openTabs: [OpenFileTab] = []
    public private(set) var activeTab: OpenFileTab?
    public private(set) var showHidden: Bool = false

    public init(loader: WorkspaceLoader = WorkspaceLoader()) {
        self.loader = loader
    }

    public func openWorkspace(at path: String) throws {
        rootNode = try loader.load(rootPath: path)
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
