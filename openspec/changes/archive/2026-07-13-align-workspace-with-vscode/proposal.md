## Why

While dogfooding, the workspace feature is unusable next to VS Code: Logos models a workspace as a single root folder plus a bespoke .logosconfig.yaml, while the user organizes projects as VS Code workspaces (multi-root .code-workspace files). Since Logos is positioned as a VS Code-like host for Claude Code (VS Code for editing, Logos for hosting Claude), the two tools diverging on what a "workspace" is breaks the round trip. Logos should open and understand the same workspace definition VS Code already uses.

## What Changes

- Introduce a Workspace value type as the workspace definition: an ordered set of root folders plus provenance (opened from a .code-workspace file vs. an ad-hoc single folder) plus optional settings. WorkspaceModel derives its roots from this instead of holding a single rootNode.
- **BREAKING** (internal API): WorkspaceModel exposes multiple roots (roots: [FileNode]) instead of a single rootNode: FileNode?. Sidebar views render one collapsible section per root.
- Parse VS Code .code-workspace files (read-only): honor the folders array, resolving each folder path relative to the .code-workspace file's directory (and absolute paths as given). A plain-directory open normalizes to a one-root Workspace (backward compatible).
- Persist and restore a workspace definition instead of a single last-path string, migrating the existing logos.lastWorkspacePath value without dropping the user's last workspace.
- Determine a spawned claude session's working directory deterministically as the workspace's first folder.
- Add a narrow .vscode/settings.json reader seam that honors zero setting keys in this change (structure only), while the tree walk keeps skipping the .vscode directory.

## Capabilities

### New Capabilities

- `workspace`: how Logos defines, opens, persists, and presents a workspace — aligned with the VS Code workspace protocol (multi-root .code-workspace folders), including the session working-directory rule and the boundary against editor-only concerns.

### Modified Capabilities

(none)

## Impact

- Affected specs: new capability `workspace`
- Affected code:
  - New:
    - Sources/Logos/Models/Workspace.swift
    - Sources/Logos/Services/CodeWorkspaceReader.swift
    - Tests/LogosTests/CodeWorkspaceReaderTests.swift
    - Tests/LogosTests/WorkspaceTests.swift
  - Modified:
    - Sources/Logos/Models/WorkspaceModel.swift
    - Sources/Logos/Services/WorkspaceLoader.swift
    - Sources/Logos/Services/WorkspacePersistence.swift
    - Sources/Logos/Views/Sidebar/SidebarView.swift
    - Sources/Logos/Views/Sidebar/FileTreeView.swift
    - Sources/Logos/Views/Sidebar/SidebarHeader.swift
    - Sources/Logos/App/MainScene.swift
    - Tests/LogosTests/WorkspaceModelTests.swift
    - Tests/LogosTests/WorkspaceLoaderTests.swift
  - Removed:
    - (none)
