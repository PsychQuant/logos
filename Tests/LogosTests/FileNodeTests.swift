import Testing
import Foundation
@testable import Logos

@Suite("FileNode", .serialized)
struct FileNodeTests {

    @Test("file node has no children")
    func fileLeaf() {
        let f = FileNode(path: "/tmp/x.txt", kind: .file)
        #expect(f.children == nil)
        #expect(f.kind == .file)
    }

    @Test("directory node can have children")
    func directoryChildren() {
        let dir = FileNode(
            path: "/tmp/d",
            kind: .directory,
            children: [
                FileNode(path: "/tmp/d/a.txt", kind: .file),
                FileNode(path: "/tmp/d/b.txt", kind: .file)
            ]
        )
        #expect(dir.children?.count == 2)
    }

    @Test("displayName is final path component")
    func displayName() {
        let f = FileNode(path: "/foo/bar/baz.swift", kind: .file)
        #expect(f.displayName == "baz.swift")
    }

    @Test("id stable based on path")
    func idStable() {
        let f1 = FileNode(path: "/x", kind: .file)
        let f2 = FileNode(path: "/x", kind: .file)
        #expect(f1.id == f2.id)
    }

    @Test("isHidden detects dotfiles")
    func hiddenDotfile() {
        #expect(FileNode(path: "/x/.git", kind: .directory).isHidden == true)
        #expect(FileNode(path: "/x/README.md", kind: .file).isHidden == false)
    }
}
