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

    // MARK: - files.exclude globs (#97 Slice 1)

    @Test("excludeGlobs drop matching entries additively with the skipNames floor")
    func excludeGlobsDropEntries() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: "\(tmp)/dist", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(tmp)/.git", withIntermediateDirectories: true)  // skipNames floor
        try "x".write(toFile: "\(tmp)/keep.swift", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(tmp)/debug.log", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp, excludeGlobs: ["dist", "*.log"])
        let names = tree.children?.map(\.displayName).sorted() ?? []
        // dist + debug.log excluded by globs; .git by the skipNames floor; keep.swift survives.
        #expect(names == ["keep.swift"])
    }

    @Test("excludeGlobs match at any depth (**/*.ext)")
    func excludeGlobsAnyDepth() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: "\(tmp)/sub", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/sub/nested.log", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(tmp)/sub/keep.swift", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp, excludeGlobs: ["**/*.log"])
        let sub = tree.children?.first { $0.displayName == "sub" }
        let names = sub?.children?.map(\.displayName).sorted() ?? []
        #expect(names == ["keep.swift"])   // nested.log excluded at depth
    }

    @Test("a bare files.exclude pattern is root-anchored, not any-depth (VS Code semantics)")
    func excludeGlobsBareIsRootAnchored() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: "\(tmp)/build", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(tmp)/src/build", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/src/build/out.o", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp, excludeGlobs: ["build"])
        let top = tree.children?.map(\.displayName).sorted() ?? []
        #expect(!top.contains("build"))   // root-level build/ hidden
        #expect(top.contains("src"))      // src/ kept

        // Nested src/build/ is NOT hidden — a bare pattern anchors to the root, matching VS Code.
        let src = tree.children?.first { $0.displayName == "src" }
        #expect(src?.children?.map(\.displayName) == ["build"])
    }

    @Test("a **/ pattern hides a directory name at any depth")
    func excludeGlobsAnyDepthDirectory() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: "\(tmp)/build", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(tmp)/src/build", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/src/keep.swift", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp, excludeGlobs: ["**/build"])
        let top = tree.children?.map(\.displayName).sorted() ?? []
        #expect(!top.contains("build"))   // root build/ hidden

        // Nested src/build/ ALSO hidden — **/ matches at every depth.
        let src = tree.children?.first { $0.displayName == "src" }
        #expect(src?.children?.map(\.displayName) == ["keep.swift"])
    }

    @Test("empty excludeGlobs is a no-op — the skipNames floor still applies, everything else kept")
    func excludeGlobsEmptyIsNoop() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: "\(tmp)/dist", withIntermediateDirectories: true)
        try "x".write(toFile: "\(tmp)/keep.swift", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp, excludeGlobs: [])
        let names = tree.children?.map(\.displayName).sorted() ?? []
        #expect(names == ["dist", "keep.swift"])   // nothing excluded; dist survives (not in skipNames)
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

    // MARK: - #14 system /var subtree any-depth block (with /var/folders carve-out)

    @Test("isSystemPath: listed /var system subtrees blocked any-depth, /var/folders stays open")
    func isSystemPath_varSubtreeBlocking() {
        func c(_ p: String) -> String { WorkspaceLoader.canonical(p) }

        // Listed system subtrees under /var are blocked as roots (exact) …
        #expect(WorkspaceLoader.isSystemPath(c("/var/db")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/var/log")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/var/root")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/var/vm")) == true)
        // … and at any depth beneath them.
        #expect(WorkspaceLoader.isSystemPath(c("/var/db/foo")) == true)
        #expect(WorkspaceLoader.isSystemPath(c("/var/log/system.log")) == true)
        // Critical carve-out: the per-user temp tree must stay openable.
        #expect(WorkspaceLoader.isSystemPath(c("/var/folders")) == false)
        #expect(WorkspaceLoader.isSystemPath(c("/var/folders/ab/cd/T/proj")) == false)
        // Regression guard: /var itself is still exact-blocked (existing behavior).
        #expect(WorkspaceLoader.isSystemPath(c("/var")) == true)
    }

    @Test("load refuses /var system subtree roots (end-to-end)")
    func load_refusesVarSystemSubtreeRoots() {
        let loader = WorkspaceLoader()
        for sysPath in ["/var/db", "/var/log", "/var/root"] {
            let canonical = WorkspaceLoader.canonical(sysPath)
            #expect(throws: WorkspaceLoader.LoaderError.refusedSystemPath(canonical)) {
                try loader.load(rootPath: sysPath)
            }
        }
    }

    @Test("load allows a workspace under /var/folders (carve-out stays open)")
    func load_allowsVarFoldersSubtree() throws {
        // NSTemporaryDirectory() resolves under /var/folders; a dir created there
        // must NOT be refused as a system path — guards the carve-out.
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        #expect(WorkspaceLoader.canonical(tmp).hasPrefix("/var/folders/"))
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader().load(rootPath: tmp)
        #expect(tree.children?.map(\.displayName) == ["a.txt"])
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

    // MARK: - #14 package real-vs-fake structural discrimination

    @Test("a plain dir named *.photoslibrary (no bundle markers) is walked normally, not locked")
    func walk_doesNotLockFakePackageDir() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Same name as a TCC package extension, but contains no bundle signature
        // children (no originals/database/Photos.sqlite) → a plain folder.
        let fake = "\(dir)/Foo.photoslibrary"
        try FileManager.default.createDirectory(atPath: "\(fake)/src", withIntermediateDirectories: true)
        try "r".write(toFile: "\(fake)/README.md", atomically: true, encoding: .utf8)

        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: dir)
        let node = tree.children?.first { $0.displayName == "Foo.photoslibrary" }
        #expect(node?.isProtected == false)
        #expect(node?.children != nil)
        #expect(node?.children?.map(\.displayName).sorted() == ["src", "README.md"].sorted())
    }

    @Test("an unreadable real-marker package stays locked (fail-safe on read error)")
    func walk_locksUnreadableRealPackage() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pkg = "\(dir)/Locked.photoslibrary"
        try FileManager.default.createDirectory(atPath: "\(pkg)/originals", withIntermediateDirectories: true)
        // chmod 0o000 so looksLikeRealPackage's contentsOfDirectory read fails →
        // must default to true (keep locking) rather than exposing contents.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: pkg)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pkg)
        }

        let tree = try WorkspaceLoader(homeDirectory: home).load(rootPath: dir)
        let node = tree.children?.first { $0.displayName == "Locked.photoslibrary" }
        #expect(node?.isProtected == true)
        #expect(node?.children == nil)
    }

    @Test("isTCCPath discriminates real package (true) from same-named plain dir (false)")
    func isTCCPath_realVsFakePackage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = "\(dir)/Real.photoslibrary"
        try FileManager.default.createDirectory(atPath: "\(real)/originals", withIntermediateDirectories: true)
        let fake = "\(dir)/Fake.photoslibrary"
        try FileManager.default.createDirectory(atPath: "\(fake)/src", withIntermediateDirectories: true)

        let loader = WorkspaceLoader()
        #expect(loader.isTCCPath(WorkspaceLoader.canonical(real)) == true)
        #expect(loader.isTCCPath(WorkspaceLoader.canonical(fake)) == false)
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

    @Test("load halts a RUNNING walk between siblings after one was visited, not at the entry guard")
    func load_cancelStopsRunningWalk() throws {
        // #15 (2): the existing load_cancelsWhenFlagSet passes `isCancelled:{true}`,
        // which throws at the ROOT entry-guard having visited ZERO entries. This
        // test instead lets the walk make progress — the root entry guard and the
        // first child subtree (d0) are walked with the flag false — and only flips
        // the flag once d0 has been entered, so the running walk is cancelled
        // BETWEEN siblings. Deterministic (no Task.sleep): the flag is driven by
        // the childWalkHook firing for d0, not by timing.
        //
        // Mutation-detectable: if cooperative cancellation were not polled while
        // the walk runs, it would visit d1 and d2 too — the assertions below would
        // fail because their hooks would have fired and load() would have returned
        // a full tree instead of throwing.
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // Sibling subdirectories (dirs sort first); each holds a file so it is
        // genuinely walked. Entering d0 flips the cancel flag; d1/d2 must then be
        // skipped because the running walk is cancelled before reaching them.
        for d in ["d0", "d1", "d2"] {
            try FileManager.default.createDirectory(atPath: "\(tmp)/\(d)", withIntermediateDirectories: true)
            try "x".write(toFile: "\(tmp)/\(d)/inner.txt", atomically: true, encoding: .utf8)
        }
        let d0 = WorkspaceLoader.canonical("\(tmp)/d0")
        let d1 = WorkspaceLoader.canonical("\(tmp)/d1")
        let d2 = WorkspaceLoader.canonical("\(tmp)/d2")

        // Shared, lock-guarded state so the @Sendable closures are safe under
        // Swift 6 strict concurrency. The probe records which directory frames
        // were entered (the hook fires once per walked directory).
        let box = CancelProbe()
        let hook: @Sendable (String) throws -> Void = { canonical in
            box.recordEntered(canonical)
        }
        // Flag flips true only once d0's frame has been entered.
        let isCancelled: @Sendable () -> Bool = { box.entered(d0) }

        let loader = WorkspaceLoader(childWalkHook: hook)
        #expect(throws: CancellationError.self) {
            try loader.load(rootPath: tmp, isCancelled: isCancelled)
        }
        // Proof the walk was RUNNING (had made progress) when cancelled: d0 was
        // fully entered before the throw …
        #expect(box.entered(d0) == true)
        // … and the later siblings were NEVER reached — the running walk halted
        // between siblings rather than running to completion.
        #expect(box.entered(d1) == false)
        #expect(box.entered(d2) == false)
    }

    @Test("walk drops one child whose recursive frame throws a generic error, keeps siblings (line 339)")
    func walk_perChildGenericCatchSkipsOneChildKeepsSiblings() throws {
        // #15 (3): the per-child generic `catch { continue }` is distinct from the
        // line-292 contentsOfDirectory protected-leaf path. A real permission
        // denied child is turned into a protected leaf by its own frame BEFORE the
        // parent's per-child catch is reached, so this branch is unreachable from a
        // filesystem fixture. The injected childWalkHook throws a generic
        // (non-LoaderError, non-CancellationError) error for ONE child frame; the
        // throw escapes that frame and lands in the parent's per-child catch,
        // dropping only that child while its siblings survive and load() returns
        // normally (no throw).
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        for d in ["alpha", "beta", "gamma"] {
            try FileManager.default.createDirectory(atPath: "\(tmp)/\(d)", withIntermediateDirectories: true)
            try "x".write(toFile: "\(tmp)/\(d)/inner.txt", atomically: true, encoding: .utf8)
        }
        let betaCanonical = WorkspaceLoader.canonical("\(tmp)/beta")

        struct GenericChildError: Error {}
        let hook: @Sendable (String) throws -> Void = { canonical in
            if canonical == betaCanonical { throw GenericChildError() }
        }

        let loader = WorkspaceLoader(childWalkHook: hook)
        // load() must NOT throw — the generic child error is swallowed per-child.
        let tree = try loader.load(rootPath: tmp)
        let names = tree.children?.map(\.displayName).sorted() ?? []
        // beta dropped; alpha and gamma survive.
        #expect(names == ["alpha", "gamma"])
        #expect(tree.children?.contains { $0.displayName == "beta" } == false)
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

    /// Thread-safe one-shot box for the `walkProbe` callback, which is
    /// `@Sendable` and fires on the walk's own thread (#106).
    private final class ThreadFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func record(_ v: Bool) { lock.lock(); defer { lock.unlock() }; if value == nil { value = v } }
        var recorded: Bool? { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("loadAsync does not block its caller's actor")
    @MainActor
    func loadAsync_doesNotBlockCaller() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "x".write(toFile: "\(tmp)/a.txt", atomically: true, encoding: .utf8)

        // #106: DIRECT observation, not a timing proxy.
        //
        // This used to race a 5ms MainActor sentinel against a deliberately huge
        // (~2500-entry) fixture and assert a tick count. That measured scheduler
        // throughput, not actor availability: under a fully parallel `swift test`
        // the sentinel competes with every other suite, so a perfectly healthy
        // walk was observed ticking only 2-3× and tripping the `>= 4` threshold —
        // a hard-gate red with nothing to do with this code.
        //
        // Lowering the threshold does NOT fix it. Measured by perturbation
        // (forcing the walk onto MainActor via `MainActor.run`): a blocking
        // loader ticks EXACTLY 1 — structurally, from the suspension before it
        // grabs MainActor — while the healthy case under load reaches 2. No
        // threshold separates 1 from 2 reliably, so the whole tick-count
        // approach was abandoned.
        //
        // `walkProbe` reports the thread the walk actually ran on. Deterministic,
        // no sleeps, and it lets the fixture shrink from 2500 entries to one file
        // (nothing here depends on the walk taking measurable time any more).
        let flag = ThreadFlag()
        var loader = WorkspaceLoader()
        loader.walkProbe = { flag.record(Thread.isMainThread) }

        _ = try await loader.loadAsync(rootPath: tmp)

        #expect(flag.recorded == false,
                "the walk ran on the main thread — loadAsync is occupying its caller's actor")
    }

    private static func treeDepth(_ node: FileNode) -> Int {
        1 + (node.children?.map { treeDepth($0) }.max() ?? 0)
    }

    /// Lock-guarded shared state for the running-walk cancel test (#15). The
    /// `childWalkHook` and `isCancelled` closures are `@Sendable` and run on the
    /// same synchronous walk thread, but Swift 6 requires the captured state to
    /// be safe to share regardless. Records which directory frames were entered.
    private final class CancelProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var enteredPaths: Set<String> = []

        func recordEntered(_ canonical: String) {
            lock.lock(); enteredPaths.insert(canonical); lock.unlock()
        }
        func entered(_ canonical: String) -> Bool {
            lock.lock(); defer { lock.unlock() }; return enteredPaths.contains(canonical)
        }
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "logos-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
