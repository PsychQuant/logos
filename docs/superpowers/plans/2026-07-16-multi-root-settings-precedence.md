# Multi-root `files.exclude` Settings Precedence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Honor a `.code-workspace` top-level `settings.files.exclude` layered with each folder's `.vscode/settings.json` `files.exclude`, matching VS Code's key-by-key object merge (folder wins per key, including a folder `false` un-hiding a workspace exclude).

**Architecture:** The per-folder merge produces a `[String]` of enabled globs that feeds the existing Slice-1 `ExcludeGlobMatcher` unchanged. Work is confined to the two readers (`VSCodeSettingsReader`, `CodeWorkspaceReader`), the `Workspace` model, a pure merge function, and the `WorkspaceModel` wiring. `ExcludeGlobMatcher` and `WorkspaceLoader.walk` are untouched.

**Tech Stack:** Swift 6, SwiftPM, swift-testing (`import Testing`, `@Suite`/`@Test`/`#expect`). Design spec: `docs/superpowers/specs/2026-07-15-multi-root-settings-precedence-design.md`.

## Global Constraints

- Swift 6 / SwiftPM; UI-less service + model code (no SwiftUI in scope).
- swift-testing only (no XCTest). Per-suite temp dirs via `NSTemporaryDirectory() + UUID` + `defer` cleanup.
- **Commit discipline (IDD):** issue ref goes in the commit **body** as `Refs #97`. NEVER put a close/fix/resolve keyword adjacent to `#97`, and never `feat: #97 …` / `fix: #97 …` in the subject (auto-close trap). Subjects are clean conventional-commit lines.
- **No behavior change to Slice 1's single-folder path** — a folder-only open must load identically.
- **Clean-build gate (project rule):** the final verification uses `rm -rf .build && swift test` — a warm `.build` can exit green while running only a handful of tests. The one tolerated failure is the documented `WorkspaceLoaderTests` "loadAsync does not block its caller's actor" timing flake; every other test must pass.
- No emoji in code or comments.

---

### Task 1: `VSCodeSettingsReader` — `filesExcludeMap` source of truth

Make the reader expose a raw key→enabled map (so a present-`false` key survives for later override), with the enabled-only `[String]` becoming a derived view. Slice-1 behavior of `filesExclude`/`honoredKeys` is preserved.

**Files:**
- Modify: `Sources/Logos/Services/VSCodeSettingsReader.swift`
- Test: `Tests/LogosTests/VSCodeSettingsReaderTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `VSCodeSettingsReader.Settings.filesExcludeMap: [String: Bool]` (stored, public)
  - `VSCodeSettingsReader.Settings.filesExclude: [String]` (now a computed property: enabled keys, sorted)
  - `VSCodeSettingsReader.Settings.init(presentKeys: [String] = [], filesExcludeMap: [String: Bool] = [:])`
  - `static func VSCodeSettingsReader.filesExcludeMap(from raw: Any?) -> [String: Bool]` (internal)

- [ ] **Step 1: Write the failing test**

Add to `Tests/LogosTests/VSCodeSettingsReaderTests.swift` (inside `struct VSCodeSettingsReaderTests`, after `filesExcludeEnabledOnly`):

```swift
@Test("filesExcludeMap retains every present key (incl. false); filesExclude derives enabled-only")
func filesExcludeMapRetainsPresentKeys() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    // dist:true enabled; keep:false present-but-disabled; n:1 present-but-disabled (integer, not bool)
    try writeSettings(#"{ "files.exclude": { "dist": true, "keep": false, "n": 1 } }"#, into: dir)

    let s = VSCodeSettingsReader.read(folderPath: dir)
    #expect(s.filesExcludeMap == ["dist": true, "keep": false, "n": false])  // all present; enabled = value===true
    #expect(s.filesExclude == ["dist"])                                       // derived: enabled-only, sorted
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter filesExcludeMapRetainsPresentKeys`
Expected: FAIL to compile — `Settings` has no member `filesExcludeMap`.

- [ ] **Step 3: Write minimal implementation**

Replace the `Settings` struct and the private `enabledExcludes` in `Sources/Logos/Services/VSCodeSettingsReader.swift` so the file reads (keep `import Foundation`, the enum, the `read` doc comment, and `isEnabled` intact):

```swift
    public struct Settings: Equatable, Sendable {
        public let presentKeys: [String]

        /// Every key present in the `files.exclude` object → whether it is enabled (its value is
        /// a genuine JSON `true`). Present-but-`false` keys are retained so a folder can override
        /// (un-hide) a workspace-level exclude in the multi-root merge (#97). Source of truth.
        public let filesExcludeMap: [String: Bool]

        public init(presentKeys: [String] = [], filesExcludeMap: [String: Bool] = [:]) {
            self.presentKeys = presentKeys
            self.filesExcludeMap = filesExcludeMap
        }

        /// The enabled `files.exclude` patterns (value `true`), sorted. Derived from
        /// `filesExcludeMap` — the single-folder view Slice 1 exposed; behavior is unchanged.
        public var filesExclude: [String] {
            filesExcludeMap.filter { $0.value }.keys.sorted()
        }

        /// The keys Logos interprets as behavior. `files.exclude` is honored when it has >=1
        /// enabled pattern; other keys remain unhonored pending later slices.
        public var honoredKeys: [String] {
            filesExclude.isEmpty ? [] : ["files.exclude"]
        }

        /// The result when there is nothing to read (absent / malformed settings).
        public static let neutral = Settings(presentKeys: [], filesExcludeMap: [:])
    }
```

Change the `read` return (currently `filesExclude: enabledExcludes(...)`) to:

```swift
        return Settings(presentKeys: Array(obj.keys),
                        filesExcludeMap: filesExcludeMap(from: obj["files.exclude"]))
```

Replace the private `enabledExcludes(_:)` with this internal shared parser (leave `isEnabled` unchanged directly below it):

```swift
    /// Parse a `files.exclude`-shaped JSON value into a key→enabled map. VS Code's shape is
    /// `{ "<glob>": <bool | { when: … }> }`; every present key is retained with
    /// `enabled = (value is a genuine JSON true)`. Reused for a folder's `.vscode/settings.json`
    /// and a `.code-workspace` top-level `settings.files.exclude` (#97). Lenient — a non-object
    /// (or nil) yields an empty map.
    static func filesExcludeMap(from raw: Any?) -> [String: Bool] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var map: [String: Bool] = [:]
        for (key, value) in dict { map[key] = isEnabled(value) }
        return map
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VSCodeSettingsReader`
Expected: PASS — the new test plus every existing Slice-1 test (`filesExcludeEnabledOnly`, `filesExcludeEmptyHonorsNothing`, `filesExcludeConditionalIgnored`, `filesExcludeIntegerNotEnabled`, `absentNeutral`, `walkOmitsVscode`) all green (they assert the derived `filesExclude`/`honoredKeys`, whose behavior is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/Logos/Services/VSCodeSettingsReader.swift Tests/LogosTests/VSCodeSettingsReaderTests.swift
git commit -F - <<'MSG'
refactor: make VSCodeSettingsReader.filesExcludeMap the source of truth

Store every present files.exclude key -> enabled (value===true); derive the
enabled-only filesExclude [String] from it. Retaining present-but-false keys is
what lets a folder override a workspace-level exclude in the coming multi-root
merge. Slice-1 filesExclude/honoredKeys behavior is unchanged. Extracts the
shared filesExcludeMap(from:) parser.

Refs #97
MSG
```

---

### Task 2: `resolvedExcludes` merge function

A pure function that merges a workspace-scope and a folder-scope map into the enabled patterns for one folder, folder winning per key.

**Files:**
- Modify: `Sources/Logos/Services/VSCodeSettingsReader.swift`
- Test: `Tests/LogosTests/VSCodeSettingsReaderTests.swift`

**Interfaces:**
- Consumes: `[String: Bool]` maps (from Task 1's `filesExcludeMap` and Task 3's `Workspace.workspaceExcludes`).
- Produces: `static func VSCodeSettingsReader.resolvedExcludes(workspace: [String: Bool], folder: [String: Bool]) -> [String]` (internal).

- [ ] **Step 1: Write the failing test**

Add to `Tests/LogosTests/VSCodeSettingsReaderTests.swift`:

```swift
@Test("resolvedExcludes: folder merges over workspace, folder wins incl. false-override")
func resolvedExcludesMerge() {
    // union + folder-wins: folder's false un-hides the workspace-hidden **/*.log
    #expect(VSCodeSettingsReader.resolvedExcludes(
        workspace: ["dist": true, "**/*.log": true],
        folder: ["**/*.log": false, "build": true]) == ["build", "dist"])
    // folder empty → workspace applies unchanged (sorted: "*" < "d")
    #expect(VSCodeSettingsReader.resolvedExcludes(
        workspace: ["dist": true, "**/*.log": true], folder: [:]) == ["**/*.log", "dist"])
    // workspace empty → folder applies (its false key drops out)
    #expect(VSCodeSettingsReader.resolvedExcludes(
        workspace: [:], folder: ["out": true, "keep": false]) == ["out"])
    // both empty
    #expect(VSCodeSettingsReader.resolvedExcludes(workspace: [:], folder: [:]) == [])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter resolvedExcludesMerge`
Expected: FAIL to compile — no member `resolvedExcludes`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/Logos/Services/VSCodeSettingsReader.swift`, directly below `filesExcludeMap(from:)`, add:

```swift
    /// Merge a workspace-scope and a folder-scope `files.exclude` map into the enabled patterns
    /// for one folder, matching VS Code's object-merge precedence: union of keys, the **folder**
    /// winning on conflicts (including a folder `false` un-hiding a workspace exclude). Returns
    /// the enabled (`true`) keys, sorted (#97).
    static func resolvedExcludes(workspace: [String: Bool], folder: [String: Bool]) -> [String] {
        var merged = workspace
        for (key, enabled) in folder { merged[key] = enabled }   // folder wins per key
        return merged.filter { $0.value }.keys.sorted()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter resolvedExcludesMerge`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Logos/Services/VSCodeSettingsReader.swift Tests/LogosTests/VSCodeSettingsReaderTests.swift
git commit -F - <<'MSG'
feat: add resolvedExcludes multi-root files.exclude merge

Pure merge of a workspace-scope and folder-scope files.exclude map into the
enabled glob list for one folder: union of keys, folder wins per key (a folder
false un-hides a workspace exclude), enabled keys sorted. Not wired in yet.

Refs #97
MSG
```

---

### Task 3: `Workspace.workspaceExcludes` + `CodeWorkspaceReader` parse

Give `Workspace` a workspace-scope field and have `CodeWorkspaceReader` populate it from the `.code-workspace` `settings.files.exclude`. Defaulted so `adHoc` and existing constructors are source-compatible.

**Files:**
- Modify: `Sources/Logos/Models/Workspace.swift`
- Modify: `Sources/Logos/Services/CodeWorkspaceReader.swift`
- Test: `Tests/LogosTests/CodeWorkspaceReaderTests.swift`

**Interfaces:**
- Consumes: `VSCodeSettingsReader.filesExcludeMap(from:)` (Task 1).
- Produces:
  - `Workspace.workspaceExcludes: [String: Bool]` (stored, public)
  - `Workspace.init?(source:folders:workspaceExcludes:)` (new defaulted param `= [:]`)

- [ ] **Step 1: Write the failing test**

Add to `Tests/LogosTests/CodeWorkspaceReaderTests.swift` (inside the suite, e.g. after `resolvesInOrder`):

```swift
@Test("parses top-level settings.files.exclude into workspaceExcludes; empty when absent/adHoc")
func parsesWorkspaceExcludes() throws {
    let base = try makeBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    try mkdir("\(base)/proj/app")
    let wsFile = "\(base)/proj/project.code-workspace"
    try writeWorkspaceFile(wsFile, json: """
    { "folders": [ { "path": "app" } ],
      "settings": { "files.exclude": { "dist": true, "keep": false } } }
    """)
    let ws = try CodeWorkspaceReader.read(codeWorkspaceFile: wsFile)
    #expect(ws.workspaceExcludes == ["dist": true, "keep": false])   // present keys, enabled = value===true

    // No settings block → empty
    let bare = "\(base)/proj/bare.code-workspace"
    try writeWorkspaceFile(bare, json: #"{ "folders": [ { "path": "app" } ] }"#)
    #expect(try CodeWorkspaceReader.read(codeWorkspaceFile: bare).workspaceExcludes.isEmpty)

    // adHoc plain-folder open → empty
    #expect(CodeWorkspaceReader.adHoc(folder: "\(base)/proj/app").workspaceExcludes.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter parsesWorkspaceExcludes`
Expected: FAIL to compile — `Workspace` has no member `workspaceExcludes`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/Logos/Models/Workspace.swift`, add the stored property after `folders` and extend the failable init (leave `firstFolder` and `adHoc` unchanged — `adHoc` picks up the default):

```swift
    public let source: Source
    /// Ordered, guaranteed non-empty (enforced by `init?`).
    public let folders: [Folder]

    /// The `.code-workspace` top-level `settings.files.exclude` map (key → enabled), applied to
    /// every folder in the multi-root merge (#97). Empty for an adHoc folder open or a workspace
    /// file with no `settings` block.
    public let workspaceExcludes: [String: Bool]

    /// Fails (returns nil) when `folders` is empty — the non-empty invariant. Callers that
    /// resolve a `.code-workspace` treat a nil here (no surviving folder) as a load error.
    public init?(source: Source, folders: [Folder], workspaceExcludes: [String: Bool] = [:]) {
        guard !folders.isEmpty else { return nil }
        self.source = source
        self.folders = folders
        self.workspaceExcludes = workspaceExcludes
    }
```

In `Sources/Logos/Services/CodeWorkspaceReader.swift`, replace the final `Workspace(...)` construction in `read` (currently `Workspace(source: .codeWorkspaceFile(path: path), folders: resolved)`):

```swift
        let workspaceExcludes = VSCodeSettingsReader.filesExcludeMap(
            from: (obj["settings"] as? [String: Any])?["files.exclude"])
        guard let workspace = Workspace(source: .codeWorkspaceFile(path: path),
                                        folders: resolved,
                                        workspaceExcludes: workspaceExcludes) else {
            throw ReadError.noSurvivingFolders
        }
        return workspace
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CodeWorkspaceReader`
Expected: PASS — the new test plus all existing `CodeWorkspaceReader` tests (including `ignoresNonGoalKeys`, which still holds: `settings` is now read for `files.exclude` only, and `launch`/`tasks`/`extensions` remain ignored).

- [ ] **Step 5: Commit**

```bash
git add Sources/Logos/Models/Workspace.swift Sources/Logos/Services/CodeWorkspaceReader.swift Tests/LogosTests/CodeWorkspaceReaderTests.swift
git commit -F - <<'MSG'
feat: parse .code-workspace settings.files.exclude into Workspace

Workspace gains a workspaceExcludes [String:Bool] field (defaulted, so adHoc and
existing callers are unchanged); CodeWorkspaceReader populates it from the
top-level settings.files.exclude via the shared parser. Only files.exclude is
read from the settings block; launch/tasks/extensions stay ignored. Not consumed
by the loader yet.

Refs #97
MSG
```

---

### Task 4: `WorkspaceModel` wiring + integration + docs

Merge workspace + folder excludes per folder in both load paths, feeding the loader. This makes the feature live end-to-end.

**Files:**
- Modify: `Sources/Logos/Models/WorkspaceModel.swift` (sync `openWorkspace` ~lines 53-57; async `performLoad` folder loop ~lines 105-115)
- Modify: `CHANGELOG.md`
- Test: `Tests/LogosTests/WorkspaceModelTests.swift`

**Interfaces:**
- Consumes: `VSCodeSettingsReader.resolvedExcludes(workspace:folder:)` (Task 2), `VSCodeSettingsReader.read(...).filesExcludeMap` (Task 1), `Workspace.workspaceExcludes` (Task 3).
- Produces: no new symbols — behavior only.

- [ ] **Step 1: Write the failing test**

Add to `Tests/LogosTests/WorkspaceModelTests.swift` in the `// MARK: - Multi-root workspace (#96)` section, mirroring the actor annotation of the existing `filesExcludeHonoredOnLoad` integration test (WorkspaceModel is `@MainActor`, so the test runs on the main actor the same way that test does):

```swift
@Test("multi-root: workspace files.exclude applies per folder; a folder false-override un-hides")
@MainActor
func multiRootExcludePrecedence() throws {
    let base = NSTemporaryDirectory() + "logos-wm-mr-\(UUID().uuidString)"
    let fm = FileManager.default
    defer { try? fm.removeItem(atPath: base) }
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

    let model = WorkspaceModel(loader: WorkspaceLoader())
    try model.openWorkspace(at: wsFile)

    #expect(model.roots.count == 2)
    // Folder A: workspace exclude hides root-level dist/ (bare pattern = root-anchored).
    #expect((model.roots[0].children?.map(\.displayName).sorted() ?? []) == ["keep.swift"])
    // Folder B: its false override un-hides dist/.
    #expect((model.roots[1].children?.map(\.displayName) ?? []).contains("dist"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter multiRootExcludePrecedence`
Expected: FAIL — folder A currently shows `dist` too (workspace excludes not yet applied), so `model.roots[0].children` is `["dist", "keep.swift"]`, not `["keep.swift"]`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/Logos/Models/WorkspaceModel.swift`, sync `openWorkspace` — replace the `roots = try workspace.folders.map { … }` body:

```swift
        roots = try workspace.folders.map { folder in
            // #97: merge the workspace-level settings.files.exclude with this folder's
            // .vscode/settings.json (folder wins per key), then filter the walk.
            let excludes = VSCodeSettingsReader.resolvedExcludes(
                workspace: workspace.workspaceExcludes,
                folder: VSCodeSettingsReader.read(folderPath: folder.path).filesExcludeMap)
            return try loader.load(rootPath: folder.path, excludeGlobs: excludes)
        }
```

In the async `performLoad` folder loop, replace the exclude block:

```swift
            for folder in workspace.folders {
                // #97: read this folder's .vscode/settings.json off the main actor, then merge
                // it with the workspace-level excludes (folder wins per key); the [String:Bool]
                // inputs and [String] result are all Sendable.
                let folderPath = folder.path
                let workspaceExcludes = workspace.workspaceExcludes
                let excludes = await Task.detached {
                    VSCodeSettingsReader.resolvedExcludes(
                        workspace: workspaceExcludes,
                        folder: VSCodeSettingsReader.read(folderPath: folderPath).filesExcludeMap)
                }.value
                loaded.append(try await loader.loadAsync(rootPath: folderPath, excludeGlobs: excludes))
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter multiRootExcludePrecedence`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG**

In `CHANGELOG.md`, add under the `[Unreleased]` → `### Added` list (top), keeping the existing entries:

```markdown
- **Multi-root `files.exclude` precedence** ([#97](https://github.com/PsychQuant/logos/issues/97)).
  A `.code-workspace` top-level `settings.files.exclude` now applies to every folder, merged with
  each folder's `.vscode/settings.json` `files.exclude` the VS Code way: union of patterns, the
  folder winning per key — so a folder can un-hide a workspace-level exclude by setting it `false`.
  Builds on the per-folder support from the earlier slice.
```

- [ ] **Step 6: Clean-build gate**

Run: `rm -rf .build && swift test`
Expected: all tests pass except the one tolerated `WorkspaceLoaderTests` "loadAsync does not block its caller's actor" timing flake. Confirm the sole failure (if any) is exactly that test.

- [ ] **Step 7: Commit**

```bash
git add Sources/Logos/Models/WorkspaceModel.swift Tests/LogosTests/WorkspaceModelTests.swift CHANGELOG.md
git commit -F - <<'MSG'
feat: apply multi-root files.exclude precedence in the sidebar

Both WorkspaceModel load paths now merge the workspace-level
settings.files.exclude with each folder's .vscode/settings.json (folder wins per
key) and filter the walk with the merged list. A .code-workspace exclude applies
to every folder; a folder can un-hide it via false. The async path does the
folder read + merge off the main actor.

Refs #97
MSG
```

---

## Self-Review

**1. Spec coverage:**
- Two-scope precedence (workspace < folder) → Task 2 merge + Task 4 wiring. ✓
- Object merge, folder-wins incl. false-override → Task 2 (`resolvedExcludes`) + Task 4 integration. ✓
- `filesExcludeMap` source of truth + derived `filesExclude` → Task 1. ✓
- Shared `filesExcludeMap(from:)` → Task 1, reused in Task 3. ✓
- `Workspace.workspaceExcludes` defaulted → Task 3. ✓
- `CodeWorkspaceReader` parses `settings.files.exclude`, ignores other keys → Task 3 (test asserts; `ignoresNonGoalKeys` still holds). ✓
- Matcher / `WorkspaceLoader` unchanged → no task touches them. ✓
- Edge cases (adHoc/no-settings → empty; malformed → empty; integer/false disabled; false un-hides) → Task 1, Task 2, Task 3 tests. ✓
- Acceptance criteria 1-4 → Task 4 integration + Step 6 clean gate. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code step shows full code. ✓

**3. Type consistency:** `filesExcludeMap` (property, `[String: Bool]`), `filesExcludeMap(from:) -> [String: Bool]` (static), `resolvedExcludes(workspace:folder:) -> [String]`, `Workspace.workspaceExcludes: [String: Bool]`, `init?(source:folders:workspaceExcludes:)` — names and types match across Tasks 1→4. `filesExclude` stays `[String]` (derived), consumed nowhere after Task 4 (WorkspaceModel switches to `filesExcludeMap`). ✓
