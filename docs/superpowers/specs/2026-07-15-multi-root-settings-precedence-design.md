# Design: multi-root `files.exclude` settings precedence

**Issue:** [PsychQuant/logos#97](https://github.com/PsychQuant/logos/issues/97) — "Deepen VS Code workspace-protocol alignment" tracker. This is the **multi-root settings precedence** slice.
**Date:** 2026-07-15
**Status:** approved (brainstorming) — ready for implementation plan
**Predecessor:** #97 Slice 1 (`files.exclude` per-folder, commit `6614363`).

## Context

Slice 1 taught Logos to honor a single folder's `.vscode/settings.json` `files.exclude`. It has one blind spot in a multi-root workspace: a `.code-workspace` file can carry a top-level `settings` block whose `files.exclude` applies to **every** folder in the workspace. Logos ignores it today — `CodeWorkspaceReader` reads only `folders`, and `VSCodeSettingsReader` reads only per-folder `.vscode/settings.json`. So a VS Code user who sets workspace-wide excludes sees them honored in VS Code but not in Logos.

This slice closes that gap: honor the `.code-workspace` top-level `settings.files.exclude` (workspace scope), layered with each folder's `.vscode/settings.json` `files.exclude` (folder scope), matching VS Code's precedence and merge semantics.

## VS Code semantics (verified, not assumed)

Two facts from the VS Code docs drive the design:

1. **Precedence** ([multi-root-workspaces](https://code.visualstudio.com/docs/editor/multi-root-workspaces)): "folder settings can override Workspace or User settings." Order low→high: **User < Workspace (`.code-workspace` `settings`) < Folder (`.vscode/settings.json`)**. `files.exclude` is a resource-scoped setting, valid at both the workspace and folder level.
2. **Object merge** ([settings](https://code.visualstudio.com/docs/configure/settings)): "values with Object types are merged" key-by-key, and on a conflicting key "the usual override behavior occurs, with workspace values taking precedence over user values" — i.e. the higher-precedence scope wins that key, and non-conflicting keys from both scopes survive (union).

Logos has **no user-global settings scope** (it is not a VS Code install), so it maps VS Code's model onto exactly two scopes: **workspace** and **folder**. For a given folder, the effective `files.exclude` is:

> `merge(workspace_scope, folder_scope)` — union of both objects' keys, with the **folder** winning on any conflicting key.

The load-bearing consequence: a folder can set `"**/foo": false` to **un-hide** a glob the workspace hid. A "union of enabled patterns" shortcut cannot express this and would silently keep hiding `foo` — the same class of one-directional over-hiding divergence that Slice 1's root-anchored bug was. Full merge is therefore the chosen behavior (confirmed with the user).

## Design

The merge produces, per folder, a final `[String]` of enabled glob patterns that feeds the **existing Slice-1 `ExcludeGlobMatcher` unchanged**. The matcher's root-anchored-vs-any-depth rules already run per-folder-walk, so a workspace-level bare `dist` is root-anchored to *each* folder's own root — exactly VS Code's per-folder behavior. No matcher or `WorkspaceLoader.walk` change is needed; the work is in the two readers, the `Workspace` model, a merge step, and the model wiring.

### 1. Raw map as source of truth — `VSCodeSettingsReader`

The merge must know a folder *set* a key even when its value is `false` (to override), which Slice 1's enabled-only `filesExclude: [String]` cannot express. The reader's source of truth becomes a map:

```
public let filesExcludeMap: [String: Bool]   // every present key -> isEnabled(value)
```

- `isEnabled(value)` is Slice 1's existing CFBoolean-strict check (genuine JSON `true` only; integer `1`, `false`, and conditional `{ when: … }` all map to `false`). Every present key is retained, including those mapping to `false` — that is what enables a folder override.
- `filesExclude: [String]` becomes a **derived** computed property: `filesExcludeMap.filter { $0.value }.keys.sorted()`. Its observable value is identical to Slice 1's, so every Slice-1 caller and test keeps working.
- `honoredKeys` stays derived from `filesExclude` (enabled) — unchanged Slice-1 semantics: `files.exclude` is "honored" only when ≥1 pattern is actually enabled. A conditional-only or all-`false` file honors nothing.
- A new shared static exposes the parse for reuse: `filesExcludeMap(from raw: Any?) -> [String: Bool]` — the single home for the "genuine bool only" discipline, called by both this reader and `CodeWorkspaceReader`.

### 2. Workspace-scope parse — `CodeWorkspaceReader` + `Workspace`

`CodeWorkspaceReader.read` additionally parses `obj["settings"]?["files.exclude"]` through `VSCodeSettingsReader.filesExcludeMap(from:)`. Only `files.exclude` is read from the `settings` block; every other settings key stays ignored (consistent with Slice 1 and the #97 non-goal-boundary slice).

`Workspace` gains a workspace-scope field:

```
public let workspaceExcludes: [String: Bool]   // .code-workspace top-level settings.files.exclude
```

- Added to the failable `init?(source:folders:workspaceExcludes:)` as a **defaulted** parameter (`= [:]`), so `adHoc(folderPath:)` and any existing constructor call are source-compatible.
- `adHoc` (plain-folder open) and a `.code-workspace` with no `settings` block both yield `[:]`.
- `[String: Bool]` is `Equatable` + `Sendable`, preserving `Workspace`'s conformances.

Rationale for the field's home: `workspaceExcludes` is parsed from the `.code-workspace` file, so it is workspace **provenance** — the same category as `source`/`folders` — and belongs on `Workspace`. Threading a separate value through `resolveWorkspace` → `performLoad` was considered and rejected as more plumbing for no isolation benefit.

### 3. Merge step

A static on `VSCodeSettingsReader` (the owner of files.exclude resolution):

```
static func resolvedExcludes(workspace: [String: Bool], folder: [String: Bool]) -> [String]
```

Overlay `folder` onto `workspace` (folder keys win, including `false`), then return the `true` keys, sorted. Worked example:

- workspace `{ "dist": true, "**/*.log": true }`, folder `{ "**/*.log": false, "build": true }`
  → merged `{ "dist": true, "**/*.log": false, "build": true }` → **`["build", "dist"]`** (`**/*.log` un-hidden by the folder's `false`; folder won).
- folder `{}` → merged = workspace → `["**/*.log", "dist"]` (workspace applies unchanged).

### 4. Wiring — `WorkspaceModel`

Both load paths resolve per folder and pass the merged list to the loader:

```
let excludes = VSCodeSettingsReader.resolvedExcludes(
    workspace: workspace.workspaceExcludes,
    folder: VSCodeSettingsReader.read(folderPath: folder.path).filesExcludeMap)
… loader.load(rootPath: folder.path, excludeGlobs: excludes)
```

- Async path (`performLoad`): the per-folder `.vscode/settings.json` read stays off the main actor via `Task.detached` (Slice 1); `workspace.workspaceExcludes` is already in hand (no I/O).
- Sync path (`openWorkspace`): reads inline (the sync API is sync by design).

## Units and boundaries

| Unit | Responsibility | Change |
|------|----------------|--------|
| `VSCodeSettingsReader` | parse one folder's `.vscode/settings.json`; own the files.exclude bool discipline + merge | `filesExcludeMap` source of truth; `filesExclude` derived; shared `filesExcludeMap(from:)`; `resolvedExcludes(workspace:folder:)` |
| `CodeWorkspaceReader` | parse `.code-workspace` file | also parse `settings.files.exclude` into the workspace map |
| `Workspace` | workspace definition + provenance | add `workspaceExcludes: [String: Bool]` (defaulted) |
| `WorkspaceModel` | drive load, own model state | merge workspace+folder per folder, pass merged list to loader |
| `ExcludeGlobMatcher`, `WorkspaceLoader` | glob match + walk | **unchanged** — consume the merged `[String]` exactly as in Slice 1 |

## Edge cases & error handling

- **No `settings` block / adHoc folder open** → `workspaceExcludes = [:]` → merge = folder-only → identical to Slice 1.
- **Malformed `settings` or `files.exclude` value** (not an object) → `filesExcludeMap(from:)` returns `[:]` (lenient, never throws), matching Slice 1's tolerance.
- **Integer `1` / `false` / conditional value** → `isEnabled` false; key present in the map (so it can override) but not enabled.
- **Folder un-hides a workspace exclude** (`false` over `true`) → glob dropped from the merged list → entry visible. ✓
- **Same glob enabled in both scopes** → present once in the merged list (set-like); sorted output is deterministic.

## Testing (TDD)

- `VSCodeSettingsReaderTests`: `filesExcludeMap` retains present-`false` keys; integer `1` still `false`; derived `filesExclude` still enabled-only + sorted (Slice-1 assertions unchanged).
- `VSCodeSettingsReaderTests` (merge): `resolvedExcludes` — union, folder-wins on conflict, `false`-override un-hides, workspace-only, folder-only, both-empty.
- `CodeWorkspaceReaderTests`: parses top-level `settings.files.exclude` into `workspaceExcludes`; adHoc → `[:]`; `.code-workspace` with no `settings` block → `[:]`; non-object settings → `[:]`.
- `WorkspaceModelTests` (integration, real `WorkspaceLoader`): a `.code-workspace` with a workspace-level `files.exclude` plus one folder that overrides a key via `false` → each folder's loaded tree reflects its own merged set (workspace exclude hidden in the non-overriding folder, un-hidden in the overriding one).

## Non-goals (stay tracked / closed in #97)

- Honoring any `settings` key other than `files.exclude` from the `.code-workspace` block.
- A user-global settings scope (Logos has none).
- `${workspaceFolder}` / variable substitution (separate open slice).
- Conditional `{ "when": … }` evaluation (still treated as not-enabled, per Slice 1).
- Any change to `ExcludeGlobMatcher` glob semantics or `WorkspaceLoader.walk`.

## Acceptance criteria

1. A `.code-workspace` `settings.files.exclude` hides matching entries in **every** folder's sidebar tree.
2. A folder's `.vscode/settings.json` merges over the workspace set, folder winning per key, including un-hiding a workspace exclude via `false`.
3. Single-folder / adHoc opens behave exactly as in Slice 1 (no regression).
4. `rm -rf .build && swift test` green except the one documented `loadAsync` timing flake.
