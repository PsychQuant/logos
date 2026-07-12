## Context

Logos models a workspace as a single root folder. `WorkspaceModel` holds one `rootNode: FileNode?`; the sidebar (`SidebarView`, `FileTreeView`, `SidebarHeader`) renders that single tree; `WorkspacePersistence` stores one `logos.lastWorkspacePath` string; the open flow is an `NSOpenPanel` that allows a single directory. A separate `.logosconfig.yaml` (parsed by `WorkspaceConfig`) is a LaTeX/PDF live-preview build map, unrelated to which folders a workspace contains. The `.vscode` directory is currently in `WorkspaceLoader.skipNames` — treated as noise.

The user organizes projects as VS Code workspaces (multi-root `.code-workspace` files) and uses VS Code for editing while hosting Claude in Logos. The single-root model makes the sidebar unusable when the real project is a multi-folder VS Code workspace. Design doc §10.7 (session ↔ workspace: 1:1 / N:1 / N:N) is still open and is marked implementation-blocking by CLAUDE.md; multi-root makes "which folder is the session cwd" a live question.

**Interface depth check** (new module + storage abstraction): the seam is a new `Workspace` value type (Models) plus a `CodeWorkspaceReader` service (Services). One adapter converts `.code-workspace` JSON into a `Workspace`; it hides JSON parsing, folder-path resolution, single-folder normalization, and a structural settings-reader seam. Deleting the type + reader would collapse multi-root and VS Code alignment entirely — the seam earns its place.

## Goals / Non-Goals

**Goals:**

- A `Workspace` value type is the single definition of "what a workspace is": an ordered, non-empty set of resolved root folders plus provenance (opened from a `.code-workspace` file vs. an ad-hoc single folder).
- Logos reads an existing VS Code `.code-workspace` file and shows its `folders` as the same multi-root set VS Code shows.
- Opening a plain directory still works and normalizes to a one-root workspace (backward compatible).
- A spawned `claude` session's working directory is deterministic (the workspace's first folder).
- Persistence restores the previously opened workspace (file or folder) without losing the existing single-path value.

**Non-Goals:**

- Honoring any specific `.vscode/settings.json` key in this change (a reader seam is added; zero keys are interpreted). Deferred to a later change.
- Writing or maintaining a `.code-workspace` file — Logos only consumes it (VS Code owns editing/authoring).
- Resolving the full §10.7 session ↔ workspace model (N:1 / N:N). This change picks a deterministic single-cwd rule and defers the general model.
- Full VS Code variable substitution (`${workspaceFolder:...}` etc.) — only literal relative and absolute folder paths are resolved.
- Changing `.logosconfig.yaml`'s role — it remains an orthogonal, per-root build/preview map.
- Making Logos an editor (per design §11 non-goals): only workspace membership is mirrored, not editor semantics.

## Decisions

**D1 — A `Workspace` value type carries provenance, not a bare `[FileNode]`.**
`Workspace` holds an ordered non-empty `folders` list and a `source` (`.code-workspace` file path, or ad-hoc folder). `WorkspaceModel` derives `roots: [FileNode]` by loading each folder. Alternative (bare `rootNodes: [FileNode]`) was rejected: it drops provenance, which the persistence locator and future settings work both need.

**D2 — `.code-workspace` is read-only.**
Logos parses but never writes `.code-workspace`. Alternative (read-write) was rejected: co-owning a format VS Code also writes invites merge/conflict handling and scope creep, for no dogfooding benefit (VS Code authors the file).

**D3 — Folder paths resolve relative to the `.code-workspace` file's directory; absolute paths pass through.**
Matches VS Code semantics. A resolved folder that does not exist on disk is dropped with a logged note; if zero folders survive, the load surfaces a `WorkspaceLoadError` (same banner path as today). Alternative (fail the whole load on any missing folder) was rejected as too brittle for real multi-repo layouts.

**D4 — Session cwd is the workspace's first folder.**
Deterministic and predictable. Alternative (prompt per session / infer from active file) was rejected as premature — it presupposes the §10.7 model, which is out of scope here. First-folder does not foreclose a later N:N model.

**D5 — `.logosconfig.yaml` stays orthogonal and per-root; `.vscode` stays skipped in the tree walk.**
A separate, structural `.vscode/settings.json` reader seam is introduced but interprets no keys yet. Alternative (fold build config into `.code-workspace` settings) was rejected: it pushes Logos-specific config into a VS-Code-owned file VS Code would ignore or strip.

**D6 — Persistence widens the stored value from "folder path" to "workspace locator".**
The persisted string may be a `.code-workspace` file path or a folder path; on restore, a `.code-workspace` extension selects the file reader, otherwise the ad-hoc-folder path. Existing folder values already restore correctly as ad-hoc — no separate migration code or key rename is needed. Alternative (new key + explicit migration routine) was rejected as unnecessary complexity for a value that is already forward-compatible.

## Implementation Contract

**Behavior:**
- Opening a `.code-workspace` file renders one collapsible sidebar section per resolved, on-disk folder, in file order. Opening a plain directory renders exactly one section (that directory).
- The "Open Workspace…" flow accepts either a directory or a `.code-workspace` file.
- The spawned `claude` process inherits the first folder as its working directory.
- Relaunch restores the last-opened workspace (file or folder). A `.code-workspace` whose folders no longer exist restores the surviving folders; if none survive, the workspace-load error banner shows and the persisted locator is cleared (stale).

**Interface / data shape:**
- `Workspace` value type: ordered non-empty `folders` (each carrying an absolute resolved `path` and an optional display `name`) plus a `source` discriminating `.code-workspace` file vs. ad-hoc folder; exposes the first folder as the session-cwd/primary folder.
- `CodeWorkspaceReader`: a read entry point that parses a `.code-workspace` file into a `Workspace` (resolving `folders[].path` against the file's directory, absolute passthrough, dropping missing folders), and a normalizer that wraps a single directory into a one-root `Workspace`.
- `WorkspaceModel`: exposes `roots: [FileNode]` (one per workspace folder) in place of a single `rootNode`; retains its async-load, epoch-guard, and error-banner behavior per root set.
- `WorkspacePersistence`: stores/loads a single workspace-locator string (folder or `.code-workspace` file path); restore selects the reader by `.code-workspace` extension.
- A `.vscode/settings.json` reader seam exists and returns an empty/neutral result (no keys interpreted) in this change.

**Failure modes:**
- Malformed `.code-workspace` JSON → typed load error surfaced in the existing banner; persisted locator cleared only when definitively stale.
- Individual missing folder → dropped, logged at notice level (folder path is never logged — it carries username/project names; only counts/classification are `.public`, consistent with existing `Log.workspace` discipline).
- Empty surviving folder set → `WorkspaceLoadError` (nothing to display).

**Acceptance criteria:**
- Unit tests (TDD, RED-first): `CodeWorkspaceReader` resolves relative + absolute folders, drops missing folders, errors on zero-survivors and on malformed JSON; ad-hoc normalization yields one folder; `Workspace.firstFolder` is the cwd source.
- Unit tests: `WorkspaceModel` loads N roots from a multi-folder `Workspace` and one root from an ad-hoc `Workspace`; persistence round-trips both a folder locator and a `.code-workspace` locator; a pre-existing folder-only persisted value still restores as ad-hoc.
- The full `swift test` suite passes (the known `loadAsync` timing test remains the only tolerated flake).
- Manual/Track-B: opening the repo's own `logos.code-workspace` renders the expected root section(s); a plain-folder open still renders one section.

**Scope boundaries:**
- In scope: `Workspace` type, `CodeWorkspaceReader`, multi-root `WorkspaceModel`, multi-root sidebar rendering, persistence-as-locator, first-folder cwd wiring in the launch/open path, `.vscode` settings-reader seam (zero keys), open dialog accepting a `.code-workspace` file.
- Out of scope: interpreting any `.vscode/settings.json` key, `.logosconfig.yaml` restructuring, the §10.7 N:N model, `${...}` variable substitution, writing `.code-workspace` files.

## Risks / Trade-offs

- [Multi-root cwd picks the wrong folder for some users] → deterministic first-folder rule is documented and predictable; the general §10.7 model is an explicit follow-up, not silently dropped.
- [Sidebar snapshot / UI (Track B) baselines change with multi-root] → re-baseline as part of this change's test work; the change description flags it so it is not mistaken for a regression.
- [`.code-workspace` in the wild uses variables Logos does not expand] → literal relative/absolute only this change; unresolved variables leave that folder dropped-with-log rather than crashing, and full substitution is a named follow-up.
- ["Fully align" scope creep pulling in editor settings] → the `.vscode` reader interprets zero keys here; the Non-Goals draw the editor boundary explicitly.
- [Persistence semantic widening breaks an old value] → old folder-only values are a strict subset of the new locator space (no `.code-workspace` extension → ad-hoc), verified by a dedicated restore test.

## Migration Plan

No data migration routine is required. `WorkspacePersistence`'s stored string is widened from "folder path" to "workspace locator"; existing `logos.lastWorkspacePath` folder values restore as ad-hoc one-root workspaces because they lack a `.code-workspace` extension. Rollback is reverting the change set; a locator written by the new code that happens to be a plain folder is still a valid input to the old single-path reader, so a forward-then-back transition does not corrupt persistence. A locator pointing at a `.code-workspace` file, if read by old code, would be treated as a (non-existent) directory and cleared as stale — a graceful degrade, not a crash.

## Open Questions

- §10.7 session ↔ workspace (1:1 / N:1 / N:N): deferred. This change fixes cwd = first folder; the general model (multiple sessions across roots, per-root sessions) is a separate change and remains design-doc-open.
- Which `.vscode/settings.json` keys (if any) Logos should eventually honor — deferred to the follow-up that gives the reader seam real behavior.
