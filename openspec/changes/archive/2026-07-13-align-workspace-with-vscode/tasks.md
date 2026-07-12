## 1. Workspace value type

- [x] 1.1 RED: add Tests/LogosTests/WorkspaceTests.swift asserting a Workspace holds an ordered non-empty folder list, a source discriminating .code-workspace-file vs ad-hoc-folder, and exposes the first folder as the primary/cwd folder. Verify: `swift test --filter WorkspaceTests` fails to compile / RED.
- [x] 1.2 GREEN: implement the Workspace value type in Sources/Logos/Models/Workspace.swift so a workspace is an ordered non-empty set of resolved folders (each with an absolute path and optional display name) plus provenance and a firstFolder accessor. Verify: `swift test --filter WorkspaceTests` passes. Spec: "A workspace is an ordered, non-empty set of root folders".

## 2. CodeWorkspaceReader (.code-workspace parsing)

- [x] 2.1 RED: add Tests/LogosTests/CodeWorkspaceReaderTests.swift covering relative-to-file and absolute folder resolution (using GIVEN /repos/myproj/project.code-workspace folders app + ../shared-lib THEN /repos/myproj/app then /repos/shared-lib), dropping a missing folder, erroring on zero survivors, erroring on malformed JSON, and ad-hoc single-folder normalization. Verify: `swift test --filter CodeWorkspaceReaderTests` RED.
- [x] 2.2 GREEN: implement Sources/Logos/Services/CodeWorkspaceReader.swift to parse a .code-workspace file into a Workspace (resolve folders against the file directory, absolute passthrough, drop missing, throw a typed load error on zero survivors or malformed JSON) and to normalize a single directory into a one-root Workspace; the reader never writes a .code-workspace file. Verify: `swift test --filter CodeWorkspaceReaderTests` passes. Spec: "Logos reads VS Code .code-workspace files read-only"; "Missing folders are dropped and an empty result is a load error".

## 3. Multi-root WorkspaceModel

- [x] 3.1 RED: extend Tests/LogosTests/WorkspaceModelTests.swift to assert the model exposes roots: [FileNode] loaded one-per-folder from a multi-folder Workspace, exactly one root from an ad-hoc Workspace, and surfaces the load-error banner when zero folders survive. Verify: `swift test --filter WorkspaceModelTests` RED on the new cases.
- [x] 3.2 GREEN: reshape WorkspaceModel in Sources/Logos/Models/WorkspaceModel.swift so it derives roots: [FileNode] from a Workspace in place of the single rootNode, preserving the async-load epoch guard and error-banner behavior across the root set. Verify: `swift test --filter WorkspaceModelTests` passes.

## 4. Persistence as workspace locator

- [x] 4.1 RED: add persistence round-trip tests asserting a .code-workspace-file locator and a folder locator each save and restore, and that a plain-folder value written before this change restores as a one-root ad-hoc workspace. Verify: the new persistence tests are RED.
- [x] 4.2 GREEN: widen Sources/Logos/Services/WorkspacePersistence.swift to store/restore a single workspace locator, selecting the .code-workspace reader by file extension and otherwise treating the locator as an ad-hoc folder, with no separate migration routine. Verify: the persistence round-trip tests pass. Spec: "The last-opened workspace is restored across launches".

## 5. Multi-root sidebar rendering

- [x] 5.1 GREEN: update Sources/Logos/Views/Sidebar/SidebarView.swift, FileTreeView.swift, and SidebarHeader.swift to render one top-level section per root in folder order and keep the NO-WORKSPACE empty state. Verify: app builds and opening the repo's own logos.code-workspace shows the expected root section(s); manual multi-root render check. Spec: "A workspace is an ordered, non-empty set of root folders".

## 6. Open dialog and session cwd

- [x] 6.1 GREEN: update Sources/Logos/App/MainScene.swift so Open Workspace accepts either a directory or a .code-workspace file, and the launch precedence resolver plus spawned claude working directory use the workspace's first folder. Verify: Track-A smoke / manual — opening a .code-workspace spawns claude with the first folder as cwd; a plain-directory open still works. Spec: "The session working directory is the workspace's first folder"; "Opening a plain directory yields a one-root workspace".

## 7. .vscode settings reader seam

- [x] 7.1 [P] GREEN: add a structural .vscode/settings.json reader seam that interprets zero setting keys (neutral result), and confirm .vscode remains in WorkspaceLoader.skipNames so it is never surfaced in the tree. Verify: a test asserts the reader changes no behavior and that a walked tree containing .vscode omits it. Spec: "Editor-only concerns are excluded".

## 8. Full suite and snapshot baselines

- [x] 8.1 Run a clean full suite and re-record changed sidebar baselines so multi-root rendering is not mistaken for a regression. Verify: `rm -rf .build && swift test` is green (only the known loadAsync timing flake tolerated) and the updated snapshot baselines assert clean on re-run.
