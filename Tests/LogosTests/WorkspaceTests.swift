import Testing
import Foundation
@testable import Logos

@Suite("Workspace")
struct WorkspaceTests {

    @Test("ordered non-empty folders + source discriminator + firstFolder")
    func basics() {
        let ws = Workspace(
            source: .codeWorkspaceFile(path: "/repos/myproj/project.code-workspace"),
            folders: [
                Workspace.Folder(path: "/repos/myproj/app"),
                Workspace.Folder(path: "/repos/shared-lib", name: "Shared"),
            ]
        )
        #expect(ws != nil)
        #expect(ws?.folders.count == 2)
        // ordered — first folder is the primary / cwd folder
        #expect(ws?.firstFolder.path == "/repos/myproj/app")
        #expect(ws?.folders[1].path == "/repos/shared-lib")
        #expect(ws?.folders[1].name == "Shared")
        #expect(ws?.source == .codeWorkspaceFile(path: "/repos/myproj/project.code-workspace"))
    }

    @Test("empty folders violates the non-empty invariant → nil")
    func emptyIsNil() {
        #expect(Workspace(source: .adHocFolder, folders: []) == nil)
    }

    @Test("adHoc factory yields exactly one folder, adHocFolder source")
    func adHoc() {
        let ws = Workspace.adHoc(folderPath: "/tmp/proj")
        #expect(ws.folders.count == 1)
        #expect(ws.firstFolder.path == "/tmp/proj")
        #expect(ws.source == .adHocFolder)
    }

    @Test("Folder name defaults to nil")
    func folderNameDefaultsNil() {
        let f = Workspace.Folder(path: "/x")
        #expect(f.name == nil)
    }
}
