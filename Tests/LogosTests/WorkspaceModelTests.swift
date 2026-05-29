import Testing
import Foundation
@testable import Logos

@Suite("WorkspaceModel", .serialized)
@MainActor
final class WorkspaceModelTests {

    // #16: a class suite so `deinit` can release the isolated UserDefaults
    // suites built during each test (no orphan plists in ~/Library/Preferences).
    private let tracker = IsolatedDefaultsTracker()
    deinit { tracker.teardown() }

    @Test("starts without workspace")
    func noWorkspace() {
        let m = makeModel()
        #expect(m.rootNode == nil)
        #expect(m.openTabs.isEmpty)
        #expect(m.activeTab == nil)
    }

    @Test("openWorkspace sets root and persists last path")
    func openWorkspace() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        // #10: isolated defaults so the save side-effect doesn't pollute
        // UserDefaults.standard (which other tests read).
        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        let m = WorkspaceModel(persistence: persistence)
        try m.openWorkspace(at: tmp)
        #expect(m.rootNode?.path == tmp)
        #expect(m.rootNode?.children?.first?.displayName == "a.txt")
        // #10: assert the previously-untested side effect — sync openWorkspace
        // persists the opened path.
        #expect(persistence.loadLastPath() == tmp)
    }

    @Test("openFile adds tab and activates")
    func openFile() {
        let m = makeModel()
        m.openFile(at: "/tmp/x.swift")
        #expect(m.openTabs.count == 1)
        #expect(m.activeTab?.path == "/tmp/x.swift")
    }

    @Test("openFile twice doesn't duplicate")
    func openFileNoDuplicate() {
        let m = makeModel()
        m.openFile(at: "/tmp/x.swift")
        m.openFile(at: "/tmp/x.swift")
        #expect(m.openTabs.count == 1)
    }

    @Test("closeTab removes and reactivates next")
    func closeTab() {
        let m = makeModel()
        m.openFile(at: "/tmp/a")
        m.openFile(at: "/tmp/b")
        m.closeTab(path: "/tmp/b")
        #expect(m.openTabs.count == 1)
        #expect(m.activeTab?.path == "/tmp/a")
    }

    @Test("toggleHidden updates flag")
    func toggleHidden() {
        let m = makeModel()
        #expect(m.showHidden == false)
        m.toggleHidden()
        #expect(m.showHidden == true)
    }

    // MARK: - Async opener + isLoading (Issue #2 Prong C)

    @Test("openWorkspaceAsync — post-conditions: isLoading clears, rootNode set")
    func openWorkspaceAsync_happyPath() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let m = makeModel()
        #expect(m.isLoading == false)

        await m.openWorkspaceAsync(at: tmp)

        #expect(m.isLoading == false)
        #expect(m.rootNode?.path == tmp)
    }

    @Test("openWorkspaceAsync — isLoading observable while detached walk runs")
    func openWorkspaceAsync_observableIsLoading() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // Enough files that the detached walk yields enough time slices for
        // the MainActor probe loop to observe `isLoading == true`.
        for i in 0..<2000 {
            try "x".write(toFile: "\(tmp)/file-\(i).txt", atomically: true, encoding: .utf8)
        }

        let m = makeModel()
        async let loadAwait: Void = m.openWorkspaceAsync(at: tmp)

        var sawLoading = false
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 1_000_000)
            if m.isLoading { sawLoading = true; break }
        }
        await loadAwait

        #expect(sawLoading == true)
        #expect(m.isLoading == false)
    }

    @Test("openWorkspaceAsync — sequential calls converge on last tree")
    func openWorkspaceAsync_sequential() async throws {
        let tmp1 = try makeTempDir()
        let tmp2 = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(atPath: tmp1)
            try? FileManager.default.removeItem(atPath: tmp2)
        }
        try "x".write(toFile: "\(tmp1)/a.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(tmp2)/b.txt", atomically: true, encoding: .utf8)

        let m = makeModel()
        await m.openWorkspaceAsync(at: tmp1)
        await m.openWorkspaceAsync(at: tmp2)

        #expect(m.rootNode?.path == tmp2)
        #expect(m.isLoading == false)
    }

    // MARK: - Cluster B deterministic concurrency (Issue #15)

    @Test("openWorkspaceAsync — stale load's defer must NOT flip isLoading off while a newer load runs")
    func openWorkspaceAsync_epochNoFlicker() async {
        // #15 (1): performLoad guards `isLoading = false` with
        // `if model.loadEpoch == myEpoch`. Two interleaved gate-mode loads
        // exercise the loadEpoch != myEpoch branch: release A (the superseded,
        // earlier-epoch load) first; its defer must leave isLoading == true
        // because B is still in flight at a newer epoch. No Task.sleep — the
        // stub's arrival/release handshake makes the ordering deterministic.
        let control = LoaderControl()
        let pathA = "/stub/A"
        let pathB = "/stub/B"
        await control.setGate(pathA, outcome: .success(FileNode(path: pathA, kind: .directory, children: [])))
        await control.setGate(pathB, outcome: .success(FileNode(path: pathB, kind: .directory, children: [])))

        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        let m = WorkspaceModel(loader: StubWorkspaceLoader(control: control), persistence: persistence)

        async let loadA: Void = m.openWorkspaceAsync(at: pathA)
        await control.waitUntilInFlight(pathA)   // A parked → epoch == 1, currentLoadTask == A
        #expect(m.isLoading == true)

        async let loadB: Void = m.openWorkspaceAsync(at: pathB)
        await control.waitUntilInFlight(pathB)   // B parked → epoch == 2 (B cancelled A's task)

        // Release the superseded load A and let its task fully finish (defer runs).
        await control.release(pathA)
        await loadA
        // A's defer saw loadEpoch (2) != myEpoch (1) → must NOT clear the spinner.
        #expect(m.isLoading == true)

        // Release the winner B; its defer's epoch matches → clears the spinner.
        await control.release(pathB)
        await loadB

        #expect(m.isLoading == false)
        #expect(m.rootNode?.path == pathB)
    }

    @Test("openWorkspaceAsync — a superseded failing load does NOT clobber the winner (stale LoaderError)")
    func openWorkspaceAsync_supersededFailDoesNotClobberWinner() async {
        // #15 (4): performLoad's catch branch has `guard !Task.isCancelled else
        // { return }`. A fails with a stale-classified LoaderError.notFound AFTER
        // B has already won. The guard must prevent A's catch from painting a
        // phantom error banner and from clearing the persisted path (.isStale).
        let control = LoaderControl()
        let pathA = "/stub/failA"
        let pathB = "/stub/winB"
        await control.setGate(pathA, outcome: .failure(.loader(.notFound(pathA))))
        await control.setImmediate(pathB, outcome: .success(FileNode(path: pathB, kind: .directory, children: [])))

        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        let m = WorkspaceModel(loader: StubWorkspaceLoader(control: control), persistence: persistence)

        async let loadA: Void = m.openWorkspaceAsync(at: pathA)
        await control.waitUntilInFlight(pathA)   // A parked (will fail when released)

        // B wins: immediate-mode load resolves with no gate; await it fully.
        await m.openWorkspaceAsync(at: pathB)
        #expect(m.rootNode?.path == pathB)
        #expect(m.lastError == nil)
        #expect(persistence.loadLastPath() == pathB)

        // Now release A so its catch runs while Task.isCancelled == true.
        await control.release(pathA)
        await loadA

        // Post-conditions UNCHANGED — A's stale failure was suppressed by the guard.
        #expect(m.rootNode?.path == pathB)
        #expect(m.lastError == nil)                       // no phantom banner
        #expect(persistence.loadLastPath() == pathB)      // not cleared by isStale branch
        #expect(m.isLoading == false)
    }

    @Test("openWorkspaceAsync — a superseded transient failure does NOT clear the persisted path")
    func openWorkspaceAsync_supersededTransientFailDoesNotClearPath() async {
        // #15 (4 variant): A fails with a transient NSError (maps to .unknown,
        // isStale == false) AFTER B wins. The same `!Task.isCancelled` guard
        // suppresses it; this case explicitly guards that the persistence.clear()
        // path stays unreached (it would only run for a stale, non-cancelled fail).
        let control = LoaderControl()
        let pathA = "/stub/transientA"
        let pathB = "/stub/winB"
        await control.setGate(pathA, outcome: .failure(.transient(domain: "test.io", code: 42)))
        await control.setImmediate(pathB, outcome: .success(FileNode(path: pathB, kind: .directory, children: [])))

        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        let m = WorkspaceModel(loader: StubWorkspaceLoader(control: control), persistence: persistence)

        async let loadA: Void = m.openWorkspaceAsync(at: pathA)
        await control.waitUntilInFlight(pathA)

        await m.openWorkspaceAsync(at: pathB)
        #expect(m.rootNode?.path == pathB)
        #expect(persistence.loadLastPath() == pathB)

        await control.release(pathA)
        await loadA

        #expect(m.rootNode?.path == pathB)
        #expect(m.lastError == nil)
        #expect(persistence.loadLastPath() == pathB)
        #expect(m.isLoading == false)
    }

    // MARK: - Error surfacing (Issue #9)

    @Test("openWorkspaceAsync surfaces lastError on a refused system path")
    func openWorkspaceAsync_surfacesError() async {
        let m = makeModel()
        #expect(m.lastError == nil)

        await m.openWorkspaceAsync(at: "/")   // refusedSystemPath

        #expect(m.lastError == .refused)
        #expect(m.rootNode == nil)
        #expect(m.isLoading == false)
    }

    @Test("a successful load clears a prior lastError")
    func openWorkspaceAsync_successClearsError() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let m = makeModel()
        await m.openWorkspaceAsync(at: "/")     // sets lastError
        #expect(m.lastError != nil)

        await m.openWorkspaceAsync(at: tmp)      // healthy → clears
        #expect(m.lastError == nil)
        #expect(m.rootNode?.path == tmp)
    }

    @Test("clearError dismisses the banner state")
    func clearError_dismisses() async {
        let m = makeModel()
        await m.openWorkspaceAsync(at: "/")
        #expect(m.lastError != nil)
        m.clearError()
        #expect(m.lastError == nil)
    }

    @Test("WorkspaceLoadError stale classification")
    func loadError_staleClassification() {
        #expect(WorkspaceLoadError.notFound.isStale == true)
        #expect(WorkspaceLoadError.notADirectory.isStale == true)
        #expect(WorkspaceLoadError.refused.isStale == true)
        #expect(WorkspaceLoadError.unknown.isStale == false)        // transient — keep path
        #expect(WorkspaceLoadError.tooLarge(found: 1, cap: 1).isStale == false)
    }

    // #10: isolated UserDefaults suite so model tests don't pollute
    // UserDefaults.standard (saveLastPath writes during open*).
    // #16: routed through the tracker so the suite is torn down in `deinit`.
    private func isolatedDefaults() -> UserDefaults {
        tracker.make(prefix: "logos.test")
    }

    private func makeModel() -> WorkspaceModel {
        WorkspaceModel(persistence: WorkspacePersistence(defaults: isolatedDefaults()))
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-wm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
