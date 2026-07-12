# workspace Specification

## Purpose

TBD - created by archiving change 'align-workspace-with-vscode'. Update Purpose after archive.

## Requirements

### Requirement: A workspace is an ordered, non-empty set of root folders

The workspace SHALL be represented as an ordered, non-empty list of resolved root folders together with a provenance discriminator recording whether it was opened from a VS Code `.code-workspace` file or from an ad-hoc single folder. The sidebar SHALL render one top-level collapsible section per root folder, in the workspace's folder order.

#### Scenario: Multi-folder workspace renders one section per folder

- **WHEN** a workspace with two root folders is presented
- **THEN** the sidebar shows two top-level sections in folder order, each rooted at its folder

#### Scenario: Single-folder workspace renders one section

- **WHEN** a workspace with exactly one root folder is presented
- **THEN** the sidebar shows exactly one top-level section rooted at that folder


<!-- @trace
source: align-workspace-with-vscode
updated: 2026-07-13
code:
  - Sources/Logos/Services/WorkspacePersistence.swift
  - Tests/LogosTests/WorkspaceTests.swift
  - Sources/Logos/Views/MainArea/TerminalPaneView.swift
  - Sources/Logos/Views/Sidebar/FileTreeView.swift
  - Sources/Logos/Views/Sidebar/SidebarHeader.swift
  - Sources/Logos/Services/CodeWorkspaceReader.swift
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/VSCodeSettingsReaderTests.swift
  - Tests/LogosTests/CodeWorkspaceReaderTests.swift
  - Tests/LogosTests/WorkspaceModelTests.swift
  - Sources/Logos/Models/WorkspaceModel.swift
  - Sources/Logos/Services/VSCodeSettingsReader.swift
  - Sources/Logos/Views/Sidebar/SidebarView.swift
  - Sources/Logos/Models/Workspace.swift
-->

---
### Requirement: Logos reads VS Code .code-workspace files read-only

Logos SHALL parse a VS Code `.code-workspace` file and construct a workspace from its `folders` array, resolving each folder path relative to the directory containing the `.code-workspace` file and passing absolute folder paths through unchanged. Logos SHALL NOT write, create, or modify any `.code-workspace` file.

#### Scenario: Folder paths resolve relative to the workspace file

- **WHEN** a `.code-workspace` file lists a relative folder path and an absolute folder path
- **THEN** the relative path is resolved against the file's directory and the absolute path is used as given
- **AND** no `.code-workspace` file is written or modified

##### Example: multi-root resolution and order

- **GIVEN** `/repos/myproj/project.code-workspace` containing folders `[{ "path": "app" }, { "path": "../shared-lib" }]`
- **WHEN** the file is opened as a workspace
- **THEN** the resolved root folders are `/repos/myproj/app` then `/repos/shared-lib`, in that order


<!-- @trace
source: align-workspace-with-vscode
updated: 2026-07-13
code:
  - Sources/Logos/Services/WorkspacePersistence.swift
  - Tests/LogosTests/WorkspaceTests.swift
  - Sources/Logos/Views/MainArea/TerminalPaneView.swift
  - Sources/Logos/Views/Sidebar/FileTreeView.swift
  - Sources/Logos/Views/Sidebar/SidebarHeader.swift
  - Sources/Logos/Services/CodeWorkspaceReader.swift
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/VSCodeSettingsReaderTests.swift
  - Tests/LogosTests/CodeWorkspaceReaderTests.swift
  - Tests/LogosTests/WorkspaceModelTests.swift
  - Sources/Logos/Models/WorkspaceModel.swift
  - Sources/Logos/Services/VSCodeSettingsReader.swift
  - Sources/Logos/Views/Sidebar/SidebarView.swift
  - Sources/Logos/Models/Workspace.swift
-->

---
### Requirement: Missing folders are dropped and an empty result is a load error

When resolving a workspace's folders, Logos SHALL drop any folder that does not exist on disk and SHALL continue with the surviving folders. If no folder survives, or if the `.code-workspace` file cannot be parsed, Logos SHALL surface a workspace-load error through the load-error banner and SHALL NOT present a partial or empty tree as success. A dropped folder's path SHALL NOT be logged; only non-identifying counts or classifications are logged.

#### Scenario: One missing folder is dropped, survivors remain

- **WHEN** a workspace's folders resolve to one existing folder and one non-existent folder
- **THEN** the existing folder is presented and the non-existent folder is omitted

#### Scenario: Zero surviving folders surfaces an error

- **WHEN** none of a workspace's folders exist on disk, or the `.code-workspace` file is malformed
- **THEN** the load-error banner is shown and no workspace tree is presented


<!-- @trace
source: align-workspace-with-vscode
updated: 2026-07-13
code:
  - Sources/Logos/Services/WorkspacePersistence.swift
  - Tests/LogosTests/WorkspaceTests.swift
  - Sources/Logos/Views/MainArea/TerminalPaneView.swift
  - Sources/Logos/Views/Sidebar/FileTreeView.swift
  - Sources/Logos/Views/Sidebar/SidebarHeader.swift
  - Sources/Logos/Services/CodeWorkspaceReader.swift
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/VSCodeSettingsReaderTests.swift
  - Tests/LogosTests/CodeWorkspaceReaderTests.swift
  - Tests/LogosTests/WorkspaceModelTests.swift
  - Sources/Logos/Models/WorkspaceModel.swift
  - Sources/Logos/Services/VSCodeSettingsReader.swift
  - Sources/Logos/Views/Sidebar/SidebarView.swift
  - Sources/Logos/Models/Workspace.swift
-->

---
### Requirement: Opening a plain directory yields a one-root workspace

The "Open Workspace…" action SHALL accept either a directory or a `.code-workspace` file. Opening a plain directory SHALL normalize to a workspace with that single directory as its only root folder, preserving backward-compatible single-folder behavior.

#### Scenario: Plain directory open

- **WHEN** the user opens a plain directory rather than a `.code-workspace` file
- **THEN** a one-root workspace is presented with that directory as its only root


<!-- @trace
source: align-workspace-with-vscode
updated: 2026-07-13
code:
  - Sources/Logos/Services/WorkspacePersistence.swift
  - Tests/LogosTests/WorkspaceTests.swift
  - Sources/Logos/Views/MainArea/TerminalPaneView.swift
  - Sources/Logos/Views/Sidebar/FileTreeView.swift
  - Sources/Logos/Views/Sidebar/SidebarHeader.swift
  - Sources/Logos/Services/CodeWorkspaceReader.swift
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/VSCodeSettingsReaderTests.swift
  - Tests/LogosTests/CodeWorkspaceReaderTests.swift
  - Tests/LogosTests/WorkspaceModelTests.swift
  - Sources/Logos/Models/WorkspaceModel.swift
  - Sources/Logos/Services/VSCodeSettingsReader.swift
  - Sources/Logos/Views/Sidebar/SidebarView.swift
  - Sources/Logos/Models/Workspace.swift
-->

---
### Requirement: The session working directory is the workspace's first folder

A spawned `claude` session's working directory SHALL be the workspace's first folder. The rule SHALL be deterministic and SHALL NOT depend on the active file, selection, or session order.

#### Scenario: First folder is the session cwd

- **WHEN** a session is spawned for a multi-folder workspace
- **THEN** its working directory is the workspace's first folder

##### Example: cwd for the resolved multi-root workspace

- **GIVEN** the resolved root folders `/repos/myproj/app` then `/repos/shared-lib`
- **WHEN** a `claude` session is spawned for that workspace
- **THEN** the session working directory is `/repos/myproj/app`


<!-- @trace
source: align-workspace-with-vscode
updated: 2026-07-13
code:
  - Sources/Logos/Services/WorkspacePersistence.swift
  - Tests/LogosTests/WorkspaceTests.swift
  - Sources/Logos/Views/MainArea/TerminalPaneView.swift
  - Sources/Logos/Views/Sidebar/FileTreeView.swift
  - Sources/Logos/Views/Sidebar/SidebarHeader.swift
  - Sources/Logos/Services/CodeWorkspaceReader.swift
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/VSCodeSettingsReaderTests.swift
  - Tests/LogosTests/CodeWorkspaceReaderTests.swift
  - Tests/LogosTests/WorkspaceModelTests.swift
  - Sources/Logos/Models/WorkspaceModel.swift
  - Sources/Logos/Services/VSCodeSettingsReader.swift
  - Sources/Logos/Views/Sidebar/SidebarView.swift
  - Sources/Logos/Models/Workspace.swift
-->

---
### Requirement: The last-opened workspace is restored across launches

Logos SHALL persist a single workspace locator identifying the last-opened workspace, where the locator is either a `.code-workspace` file path or a folder path, and SHALL restore it on the next launch. On restore, a locator ending in the `.code-workspace` extension SHALL be read as a workspace file and any other locator SHALL be treated as an ad-hoc folder. A previously persisted plain-folder value SHALL restore as a one-root ad-hoc workspace without a separate migration step.

#### Scenario: Workspace-file locator restores

- **WHEN** the last-opened workspace was a `.code-workspace` file and Logos relaunches
- **THEN** that file is read and its multi-root workspace is restored

#### Scenario: Legacy folder value restores as ad-hoc

- **WHEN** the persisted locator is a plain folder path saved before this capability existed
- **THEN** it restores as a one-root ad-hoc workspace


<!-- @trace
source: align-workspace-with-vscode
updated: 2026-07-13
code:
  - Sources/Logos/Services/WorkspacePersistence.swift
  - Tests/LogosTests/WorkspaceTests.swift
  - Sources/Logos/Views/MainArea/TerminalPaneView.swift
  - Sources/Logos/Views/Sidebar/FileTreeView.swift
  - Sources/Logos/Views/Sidebar/SidebarHeader.swift
  - Sources/Logos/Services/CodeWorkspaceReader.swift
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/VSCodeSettingsReaderTests.swift
  - Tests/LogosTests/CodeWorkspaceReaderTests.swift
  - Tests/LogosTests/WorkspaceModelTests.swift
  - Sources/Logos/Models/WorkspaceModel.swift
  - Sources/Logos/Services/VSCodeSettingsReader.swift
  - Sources/Logos/Views/Sidebar/SidebarView.swift
  - Sources/Logos/Models/Workspace.swift
-->

---
### Requirement: Editor-only concerns are excluded

Logos SHALL NOT surface the `.vscode` directory in the file tree and SHALL NOT interpret any `.vscode/settings.json` key as behavior in this capability's initial scope. The `.logosconfig.yaml` build/preview map SHALL remain an orthogonal, per-root artifact and SHALL NOT be folded into the `.code-workspace` file.

#### Scenario: .vscode is not surfaced and settings change nothing

- **WHEN** a workspace folder contains a `.vscode` directory with a `settings.json`
- **THEN** the `.vscode` directory is not shown in the tree
- **AND** no setting in `settings.json` alters Logos behavior

<!-- @trace
source: align-workspace-with-vscode
updated: 2026-07-13
code:
  - Sources/Logos/Services/WorkspacePersistence.swift
  - Tests/LogosTests/WorkspaceTests.swift
  - Sources/Logos/Views/MainArea/TerminalPaneView.swift
  - Sources/Logos/Views/Sidebar/FileTreeView.swift
  - Sources/Logos/Views/Sidebar/SidebarHeader.swift
  - Sources/Logos/Services/CodeWorkspaceReader.swift
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/VSCodeSettingsReaderTests.swift
  - Tests/LogosTests/CodeWorkspaceReaderTests.swift
  - Tests/LogosTests/WorkspaceModelTests.swift
  - Sources/Logos/Models/WorkspaceModel.swift
  - Sources/Logos/Services/VSCodeSettingsReader.swift
  - Sources/Logos/Views/Sidebar/SidebarView.swift
  - Sources/Logos/Models/Workspace.swift
-->