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

    // MARK: - Multi-root workspace (#96)

    @Test("openWorkspaceAsync loads N roots, in folder order, from a multi-folder .code-workspace")
    func multiRoot_loadsAllFoldersInOrder() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: "\(base)/proj/app", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(base)/shared", withIntermediateDirectories: true)
        try "x".write(toFile: "\(base)/proj/app/a.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(base)/shared/b.txt", atomically: true, encoding: .utf8)
        let wsFile = "\(base)/proj/project.code-workspace"
        try #"{ "folders": [ { "path": "app" }, { "path": "../shared" } ] }"#
            .write(toFile: wsFile, atomically: true, encoding: .utf8)

        let m = makeModel()
        await m.openWorkspaceAsync(at: wsFile)

        #expect(m.roots.count == 2)
        #expect(m.roots[0].path == "\(base)/proj/app")     // first folder
        #expect(m.roots[1].path == "\(base)/shared")       // ../ resolved, in order
        #expect(m.rootNode?.path == m.roots.first?.path)   // rootNode = primary root
        #expect(m.isLoading == false)
    }

    @Test("ad-hoc folder open yields exactly one root")
    func adHoc_oneRoot() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let m = makeModel()
        await m.openWorkspaceAsync(at: tmp)

        #expect(m.roots.count == 1)
        #expect(m.roots[0].path == tmp)
    }

    @Test("a .code-workspace whose folders all vanished surfaces an error and no roots")
    func multiRoot_zeroSurvivorsBanner() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: "\(base)/proj", withIntermediateDirectories: true)
        let wsFile = "\(base)/proj/project.code-workspace"
        try #"{ "folders": [ { "path": "gone" }, { "path": "also-gone" } ] }"#
            .write(toFile: wsFile, atomically: true, encoding: .utf8)

        let m = makeModel()
        await m.openWorkspaceAsync(at: wsFile)

        #expect(m.roots.isEmpty)
        #expect(m.lastError != nil)
        #expect(m.isLoading == false)
    }

    // MARK: - files.exclude honored on load (#97 Slice 1)

    @Test("files.exclude in .vscode/settings.json hides matching entries in the loaded root")
    func filesExcludeHonoredOnLoad() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: "\(tmp)/.vscode", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(tmp)/dist", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/keep.swift", atomically: true, encoding: .utf8)
        try #"{ "files.exclude": { "dist": true } }"#
            .write(toFile: "\(tmp)/.vscode/settings.json", atomically: true, encoding: .utf8)

        let m = makeModel()   // real WorkspaceLoader — exercises the reader→loader wiring
        await m.openWorkspaceAsync(at: tmp)

        let names = m.rootNode?.children?.map(\.displayName).sorted() ?? []
        #expect(names.contains("keep.swift"))
        #expect(!names.contains("dist"))       // hidden by files.exclude ( .vscode itself is skipNames)
    }

    // MARK: - Multi-root files.exclude precedence (#97)

    @Test("multi-root: workspace files.exclude applies per folder; a folder false-override un-hides")
    func multiRootExcludePrecedence() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let fm = FileManager.default
        // Folder A: dist/ + keep.swift, no .vscode override.
        try fm.createDirectory(atPath: "\(base)/a/dist", withIntermediateDirectories: true)
        try "x".write(toFile: "\(base)/a/keep.swift", atomically: true, encoding: .utf8)
        // Folder B: dist/ + a .vscode/settings.json that un-hides dist via false.
        try fm.createDirectory(atPath: "\(base)/b/dist", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(base)/b/.vscode", withIntermediateDirectories: true)
        try #"{ "files.exclude": { "dist": false } }"#
            .write(toFile: "\(base)/b/.vscode/settings.json", atomically: true, encoding: .utf8)
        // .code-workspace: two folders + a workspace-level exclude of dist.
        let wsFile = "\(base)/proj.code-workspace"
        try #"{ "folders": [ { "path": "a" }, { "path": "b" } ], "settings": { "files.exclude": { "dist": true } } }"#
            .write(toFile: wsFile, atomically: true, encoding: .utf8)

        let m = makeModel()   // real WorkspaceLoader — exercises reader→merge→loader end to end
        await m.openWorkspaceAsync(at: wsFile)

        #expect(m.roots.count == 2)
        // Folder A: workspace exclude hides root-level dist/ (bare pattern = root-anchored).
        #expect((m.roots[0].children?.map(\.displayName).sorted() ?? []) == ["keep.swift"])
        // Folder B: its false override un-hides dist/ (folder wins the merge).
        #expect((m.roots[1].children?.map(\.displayName) ?? []).contains("dist"))
    }

    // MARK: - loadCount successful-load signal (#100)

    @Test("loadCount increments on successful async and sync opens, not on failure")
    func loadCountTracksSuccessfulLoadsOnly() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.swift", atomically: true, encoding: .utf8)

        let m = makeModel()
        #expect(m.loadCount == 0)

        await m.openWorkspaceAsync(at: tmp)          // async success
        #expect(m.loadCount == 1)

        await m.openWorkspaceAsync(at: tmp)          // same-path reopen still counts (#100 reveal-on-open)
        #expect(m.loadCount == 2)

        await m.openWorkspaceAsync(at: "/System")    // refused system path → failure
        #expect(m.lastError != nil)
        #expect(m.loadCount == 2)                    // unchanged on failure

        try m.openWorkspace(at: tmp)                 // sync success
        #expect(m.loadCount == 3)
    }

    @Test("loadCount — a superseded (cancelled) load never increments")
    func loadCountSupersededLoadDoesNotIncrement() async {
        // #100 verify C3: the increment sits after `guard !Task.isCancelled`, so a
        // load that was superseded mid-flight must not count as a successful open
        // (else reveal-on-open would fire for a workspace that never landed).
        // Deterministic via the #15 LoaderControl handshake — no sleeps.
        let control = LoaderControl()
        let pathA = "/stub/A"
        let pathB = "/stub/B"
        await control.setGate(pathA, outcome: .success(FileNode(path: pathA, kind: .directory, children: [])))
        await control.setGate(pathB, outcome: .success(FileNode(path: pathB, kind: .directory, children: [])))

        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        let m = WorkspaceModel(loader: StubWorkspaceLoader(control: control), persistence: persistence)

        async let loadA: Void = m.openWorkspaceAsync(at: pathA)
        await control.waitUntilInFlight(pathA)
        async let loadB: Void = m.openWorkspaceAsync(at: pathB)   // cancels A
        await control.waitUntilInFlight(pathB)

        await control.release(pathA)   // A completes "successfully" but its task is cancelled
        await loadA
        #expect(m.loadCount == 0)      // superseded load must NOT have counted

        await control.release(pathB)
        await loadB
        #expect(m.loadCount == 1)      // only the winner counts
        #expect(m.rootNode?.path == pathB)
    }

    // MARK: - Persistence as workspace locator (#96)

    @Test("opening a .code-workspace persists the FILE locator, not the resolved folder paths")
    func persistsCodeWorkspaceLocator() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: "\(base)/proj/app", withIntermediateDirectories: true)
        let wsFile = "\(base)/proj/project.code-workspace"
        try #"{ "folders": [ { "path": "app" } ] }"#
            .write(toFile: wsFile, atomically: true, encoding: .utf8)

        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        let m = WorkspaceModel(persistence: persistence)
        await m.openWorkspaceAsync(at: wsFile)

        // The persisted locator is the .code-workspace file, NOT "/base/proj/app".
        #expect(persistence.loadLastPath() == wsFile)
        #expect(m.roots.first?.path == "\(base)/proj/app")
    }

    @Test("a folder locator round-trips and restores as a one-root ad-hoc workspace")
    func folderLocatorRoundTrips() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        let m = WorkspaceModel(persistence: persistence)
        await m.openWorkspaceAsync(at: tmp)
        #expect(persistence.loadLastPath() == tmp)

        // Restore via the same entry MainScene uses on relaunch.
        let restored = WorkspaceModel(persistence: persistence)
        await restored.openWorkspaceAsync(at: persistence.loadLastPath()!)
        #expect(restored.roots.count == 1)
        #expect(restored.roots[0].path == tmp)
    }

    @Test("a legacy plain-folder persisted value (pre-#96) restores as a one-root ad-hoc workspace")
    func legacyFolderValueRestoresAdHoc() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        // Simulate a value written before this capability existed: a bare folder path,
        // no .code-workspace extension, no migration step.
        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        persistence.saveLastPath(tmp)

        let m = WorkspaceModel(persistence: persistence)
        await m.openWorkspaceAsync(at: persistence.loadLastPath()!)
        #expect(m.roots.count == 1)
        #expect(m.roots[0].path == tmp)
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
