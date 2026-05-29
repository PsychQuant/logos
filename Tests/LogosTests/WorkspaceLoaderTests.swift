import Testing
import Foundation
@testable import Logos

@Suite("WorkspaceLoader", .serialized)
struct WorkspaceLoaderTests {

    @Test("loads simple flat workspace")
    func flat() throws {
        let tmp = try makeTempDir()
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: "\(tmp)/b.swift", atomically: true, encoding: .utf8)

        let loader = WorkspaceLoader()
        let tree = try loader.load(rootPath: tmp)
        #expect(tree.kind == .directory)
        #expect(tree.children?.map(\.displayName).sorted() == ["a.txt", "b.swift"])

        try FileManager.default.removeItem(atPath: tmp)
    }

    @Test("recurses into subdirs")
    func recurses() throws {
        let tmp = try makeTempDir()
        try FileManager.default.createDirectory(atPath: "\(tmp)/sub", withIntermediateDirectories: true)
        try "z".write(toFile: "\(tmp)/sub/c.swift", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp)
        let sub = tree.children?.first { $0.displayName == "sub" }
        #expect(sub?.kind == .directory)
        #expect(sub?.children?.first?.displayName == "c.swift")

        try FileManager.default.removeItem(atPath: tmp)
    }

    @Test("skips noise directories")
    func skipsNoise() throws {
        let tmp = try makeTempDir()
        try FileManager.default.createDirectory(atPath: "\(tmp)/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(tmp)/node_modules", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/keep.swift", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp)
        let names = tree.children?.map(\.displayName).sorted() ?? []
        #expect(names == ["keep.swift"])

        try FileManager.default.removeItem(atPath: tmp)
    }

    @Test("loads sorted alphabetically with dirs first")
    func sortedDirsFirst() throws {
        let tmp = try makeTempDir()
        try FileManager.default.createDirectory(atPath: "\(tmp)/zsub", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp)
        let names = tree.children?.map(\.displayName) ?? []
        #expect(names == ["zsub", "a.txt"])

        try FileManager.default.removeItem(atPath: tmp)
    }

    // MARK: - Safety limits (Issue #2 Prong B)

    @Test("refuses root path /")
    func refusesRoot() {
        let loader = WorkspaceLoader()
        #expect(throws: WorkspaceLoader.LoaderError.refusedSystemPath("/")) {
            try loader.load(rootPath: "/")
        }
    }

    @Test("refuses system path /System")
    func refusesSystemPath() {
        let loader = WorkspaceLoader()
        #expect(throws: WorkspaceLoader.LoaderError.refusedSystemPath("/System")) {
            try loader.load(rootPath: "/System")
        }
    }

    @Test("respects maxDepth — tree depth ≤ maxDepth")
    func respectsMaxDepth() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var current = tmp
        for label in ["a","b","c","d","e","f","g","h","i","j","k","l"] {
            current = "\(current)/\(label)"
            try FileManager.default.createDirectory(atPath: current, withIntermediateDirectories: true)
        }
        try "leaf".write(toFile: "\(current)/file.txt", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader(maxDepth: 10, maxFiles: 50_000).load(rootPath: tmp)
        #expect(Self.treeDepth(tree) <= 10)
    }

    @Test("fails fast on maxFiles")
    func failsFastOnMaxFiles() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        for i in 0..<100 {
            try "x".write(toFile: "\(tmp)/file-\(i).txt", atomically: true, encoding: .utf8)
        }

        let loader = WorkspaceLoader(maxDepth: 10, maxFiles: 50)
        #expect(throws: WorkspaceLoader.LoaderError.tooManyFiles(found: 50, cap: 50)) {
            try loader.load(rootPath: tmp)
        }
    }

    @Test("skips system paths within subtree via resolved symlink")
    func skipsSystemPathsWithinSubtree() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try "x".write(toFile: "\(tmp)/keep.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: "\(tmp)/library_link",
            withDestinationPath: "/Library"
        )

        let tree = try WorkspaceLoader().load(rootPath: tmp)
        let names = tree.children?.map(\.displayName).sorted() ?? []
        #expect(names == ["keep.txt"])
    }

    // MARK: - User-relative TCC skip (Issue #7)

    @Test("surfaces TCC-protected children of home as protected leaves (not dropped)")
    func walk_surfacesTCCChildrenOfHomeAsProtected() throws {
        // #13 (supersedes #7's drop-behavior, D4): TCC dirs are now SURFACED as
        // opaque protected leaves rather than silently removed — no silent omission.
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }

        for tcc in WorkspaceLoader.userRelativeTCCNames {
            try FileManager.default.createDirectory(atPath: "\(home)/\(tcc)", withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(atPath: "\(home)/code", withIntermediateDirectories: true)
        try "n".write(toFile: "\(home)/notes.txt", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: home)
        let children = tree.children ?? []
        let names = children.map(\.displayName).sorted()
        // All present — TCC ones surfaced, not dropped.
        #expect(Set(names) == WorkspaceLoader.userRelativeTCCNames.union(["code", "notes.txt"]))
        // TCC dirs are protected opaque leaves.
        for tcc in WorkspaceLoader.userRelativeTCCNames {
            let node = children.first { $0.displayName == tcc }
            #expect(node?.isProtected == true)
            #expect(node?.children == nil)
        }
        // Non-TCC siblings are normal.
        #expect(children.first { $0.displayName == "code" }?.isProtected == false)
        #expect(children.first { $0.displayName == "notes.txt" }?.isProtected == false)
    }

    @Test("walks a TCC path when it is the explicit root")
    func walk_allowsTCCPathAsExplicitRoot() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let documents = "\(home)/Documents"
        try FileManager.default.createDirectory(atPath: "\(documents)/proj", withIntermediateDirectories: true)
        try "x".write(toFile: "\(documents)/proj/main.swift", atomically: true, encoding: .utf8)

        // Documents is the chosen root → must be walked, not skipped.
        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: documents)
        #expect(tree.children?.map(\.displayName) == ["proj"])
    }

    @Test("surfaces a symlink resolving to a TCC path as protected")
    func walk_surfacesSymlinkedTCCChild() throws {
        // #13 (D4): a symlink whose resolved path is TCC is surfaced as protected,
        // not dropped (consistent with surface-don't-drop for TCC).
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }

        try FileManager.default.createDirectory(atPath: "\(home)/Documents", withIntermediateDirectories: true)
        let work = "\(home)/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try "x".write(toFile: "\(work)/keep.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: "\(work)/docs_link", withDestinationPath: "\(home)/Documents")

        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: work)
        let children = tree.children ?? []
        #expect(children.map(\.displayName).sorted() == ["docs_link", "keep.txt"])
        #expect(children.first { $0.displayName == "docs_link" }?.isProtected == true)
        #expect(children.first { $0.displayName == "keep.txt" }?.isProtected == false)
    }

    // MARK: - #6 path-classification (system path defence + canonicalize)

    @Test("isSystemPath: prefix-block catches resolved + firmlink + /opt, exact-block stays exact")
    func isSystemPath_classification() {
        // IMPORTANT: production always runs the path through `canonical()` BEFORE
        // isSystemPath. These assertions go through `canonical()` too so the test
        // input space matches production — the earlier literal-string version
        // masked a regression where `canonical()` collapses /private/var → /var
        // (verify finding). `c()` mirrors the real call path.
        func c(_ p: String) -> String { WorkspaceLoader.canonical(p) }

        // prefix-block — caught at any depth
        #expect(WorkspaceLoader.isSystemPath(c("/usr/local")) == true)     // firmlink (not a symlink)
        #expect(WorkspaceLoader.isSystemPath(c("/opt/homebrew")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/opt")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/System/Library/X")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/Network/foo")) == true)
        // exact-block — incl the /var,/tmp,/etc system symlinks (canonical short form)
        #expect(WorkspaceLoader.isSystemPath(c("/")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/Volumes")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/private")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/var")) == true)          // regression guard
        #expect(WorkspaceLoader.isSystemPath(c("/etc")) == true)          // regression guard
        #expect(WorkspaceLoader.isSystemPath(c("/tmp")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/private/var")) == true)  // symlink→/var canonicalizes to /var
        // allowed: descend into a chosen mount + per-user temp under /var/folders
        #expect(WorkspaceLoader.isSystemPath(c("/Volumes/Disk/proj")) == false)  // regression guard
        #expect(WorkspaceLoader.isSystemPath(c("/Users/che/code")) == false)
        #expect(WorkspaceLoader.isSystemPath(c("/Users/che/optimizer")) == false) // not /opt prefix
        // /Users (all-users container) exact-blocked but a user's home subtree allowed (#8 verify M1)
        #expect(WorkspaceLoader.isSystemPath(c("/Users")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/Users/che")) == false)
    }

    @Test("canonical collapses // and resolves ..")
    func canonical_normalizes() {
        #expect(WorkspaceLoader.canonical("/System//") == "/System")
        #expect(WorkspaceLoader.canonical("/a/b/../c") == "/a/c")
        #expect(WorkspaceLoader.canonical("/x/") == "/x")
    }

    @Test("refuses /opt as root even when nonexistent")
    func load_refusesOptRoot() {
        let loader = WorkspaceLoader()
        #expect(throws: WorkspaceLoader.LoaderError.refusedSystemPath("/opt")) {
            try loader.load(rootPath: "/opt")
        }
    }

    @Test("refuses system symlink roots /var, /etc, /tmp (end-to-end regression guard)")
    func load_refusesSystemSymlinkRoots() {
        // End-to-end through load() → canonical() → isSystemPath, the production
        // path. Guards the #6 regression where /var/etc/tmp became walkable
        // because the skip set held /private/var (which canonical never emits).
        let loader = WorkspaceLoader()
        for sysPath in ["/var", "/etc", "/tmp"] {
            let canonical = WorkspaceLoader.canonical(sysPath)
            #expect(throws: WorkspaceLoader.LoaderError.refusedSystemPath(canonical)) {
                try loader.load(rootPath: sysPath)
            }
        }
    }

    @Test("a /Volumes child root is not refused as a system path")
    func load_volumesChildNotRefused() {
        let bogus = "/Volumes/NoSuchDisk-\(UUID().uuidString)/x"
        let loader = WorkspaceLoader()
        do {
            _ = try loader.load(rootPath: bogus)
            Issue.record("expected an error")
        } catch let e as WorkspaceLoader.LoaderError {
            // Must be notFound (passed system check), NOT refusedSystemPath.
            if case .refusedSystemPath = e {
                Issue.record("/Volumes child wrongly refused as system path")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - #13 TCC any-depth + graceful catch + degenerate home

    @Test("depth-2 TCC descendant (~/Library/Mail) is a protected leaf, not descended")
    func walk_protectsDepth2TCCDescendant() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let library = "\(home)/Library"
        try FileManager.default.createDirectory(atPath: "\(library)/Mail/V10", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(library)/Developer", withIntermediateDirectories: true)

        // Open ~/Library as explicit root (root exempt) → its children walked one level.
        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: library)
        let mail = tree.children?.first { $0.displayName == "Mail" }
        #expect(mail?.isProtected == true)
        #expect(mail?.children == nil)   // NOT descended → no cascade into Mail/V10
    }

    @Test("a .photoslibrary package is an opaque protected leaf")
    func walk_protectsPhotoLibraryPackage() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: "\(dir)/Photos.photoslibrary/originals", withIntermediateDirectories: true)
        try "x".write(toFile: "\(dir)/readme.txt", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: dir)
        let pkg = tree.children?.first { $0.displayName == "Photos.photoslibrary" }
        #expect(pkg?.isProtected == true)
        #expect(pkg?.children == nil)
    }

    @Test("a permission-denied directory becomes an opaque protected leaf")
    func walk_protectsPermissionDeniedDir() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = try makeTempDir()
        let locked = "\(dir)/locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try "secret".write(toFile: "\(locked)/inside.txt", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: dir)
        let node = tree.children?.first { $0.displayName == "locked" }
        // On a non-root test runner, contentsOfDirectory throws → opaque protected leaf.
        #expect(node?.isProtected == true)
        #expect(node?.children == nil)
    }

    @Test("degenerate homeDirectory disables TCC filtering without crashing")
    func init_degenerateHomeNoTCCFiltering() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: "\(dir)/Documents", withIntermediateDirectories: true)

        for home in ["", "/"] {
            let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: dir)
            let docs = tree.children?.first { $0.displayName == "Documents" }
            // No home → "Documents" is NOT treated as TCC → walked normally.
            #expect(docs?.isProtected == false)
        }
    }

    // MARK: - Cooperative cancellation (Issue #4)

    @Test("load throws CancellationError immediately when isCancelled is true")
    func load_cancelsWhenFlagSet() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // A deep-ish tree; with isCancelled always true, the walk must throw
        // before producing a tree (no timing dependency — deterministic).
        var cur = tmp
        for label in ["a", "b", "c"] {
            cur = "\(cur)/\(label)"
            try FileManager.default.createDirectory(atPath: cur, withIntermediateDirectories: true)
        }
        for i in 0..<50 { try "x".write(toFile: "\(tmp)/f\(i).txt", atomically: true, encoding: .utf8) }

        #expect(throws: CancellationError.self) {
            try WorkspaceLoader().load(rootPath: tmp, isCancelled: { true })
        }
    }

    @Test("load completes when isCancelled is false")
    func load_completesWhenNotCancelled() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp, isCancelled: { false })
        #expect(tree.children?.map(\.displayName) == ["a.txt"])
    }

    // MARK: - Per-child error policy (Issue #9)

    @Test("a permission-denied child is skipped, siblings still loaded")
    func walk_skipsPermissionDeniedChildKeepsSiblings() throws {
        let tmp = try makeTempDir()
        let denied = "\(tmp)/denied"
        try FileManager.default.createDirectory(atPath: "\(denied)/inside", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/keep.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: "\(tmp)/normal", withIntermediateDirectories: true)
        // Deny traversal so descending into `denied` errors out.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied)
            try? FileManager.default.removeItem(atPath: tmp)
        }

        // The whole load must NOT abort — siblings (keep.txt, normal) remain.
        let tree = try WorkspaceLoader().load(rootPath: tmp)
        let names = tree.children?.map(\.displayName).sorted() ?? []
        #expect(names.contains("keep.txt"))
        #expect(names.contains("normal"))
    }

    // MARK: - Async loader (Issue #2 Prong C)

    @Test("loadAsync does not block its caller's actor")
    @MainActor
    func loadAsync_doesNotBlockCaller() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // #10: catastrophic-ish fixture — a deep, wide tree (~2500 entries over
        // 5 nested levels) whose walk takes long enough (well over the sentinel
        // tick interval, since each entry does a resolvingSymlinksInPath) that a
        // MainActor sentinel can make visible progress DURING the walk. #2's
        // original 200-flat-file fixture finished in <5ms — a placebo: the walk
        // ended before the sentinel noticed, so even a main-blocking loader
        // passed. Here we ALSO snapshot the tick count at load completion (the
        // real discriminator): if the walk ran off-MainActor, the sentinel
        // ticked while `await loadAsync` was suspended; a blocking loader would
        // leave the snapshot at ~0.
        var dir = tmp
        for level in 0..<5 {
            for f in 0..<500 {
                try "x".write(toFile: "\(dir)/f-\(level)-\(f).txt", atomically: true, encoding: .utf8)
            }
            dir = "\(dir)/sub-\(level)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        var ticks = 0
        let sentinel = Task { @MainActor in
            for _ in 0..<400 {                                   // generous cap; we snapshot, not drain
                try await Task.sleep(nanoseconds: 5_000_000)     // 5ms
                ticks += 1
            }
        }
        defer { sentinel.cancel() }

        _ = try await WorkspaceLoader().loadAsync(rootPath: tmp)
        let ticksDuringWalk = ticks  // snapshot AT load completion — the discriminator

        // Off-MainActor walk (correct) → sentinel ticked freely while suspended.
        // A MainActor-blocking loader would leave this at ~0. The walk is far
        // longer than 4×5ms, so >= 4 is a strong, non-placebo signal.
        #expect(ticksDuringWalk >= 4)
    }

    private static func treeDepth(_ node: FileNode) -> Int {
        1 + (node.children?.map { treeDepth($0) }.max() ?? 0)
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
