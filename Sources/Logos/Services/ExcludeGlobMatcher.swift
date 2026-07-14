import Foundation

/// Minimal matcher for the common VS Code `files.exclude` glob forms (#97 Slice 1).
///
/// Supported subset — a deliberate boundary; full micromatch is out of scope:
///   - `**/name`  → any entry whose leaf name is `name`, at **any depth**
///   - `**/*.ext` → any entry whose leaf name ends in `.ext`, at **any depth**
///   - `name`     → an entry named `name` that is a **direct child of the workspace root**
///   - `*.ext`    → a root-child entry whose leaf name ends in `.ext`
///
/// **Root-anchored vs any-depth** mirrors VS Code: a bare pattern (no `**/`) matches only at the
/// workspace root, while a `**/`-prefixed pattern matches at every depth. This is why VS Code's
/// own defaults (`**/.DS_Store`, `**/.git`, …) all carry `**/`. Getting this wrong in the
/// over-hiding direction (bare `build` silently hiding a nested `src/build/`) hides content the
/// user expects to see, so the distinction is honored rather than flattened.
///
/// A trailing `/` (the idiomatic gitignore "directory" marker, e.g. `**/build/` or `dist/`) is
/// stripped so the pattern still matches. Patterns that still contain a path separator after the
/// optional `**/` prefix and trailing-slash strip (e.g. `src/generated`) are **unsupported**:
/// silently ignored, never matched. Empty / malformed patterns are no-ops.
///
/// In the spirit of the codebase's existing `WorkspaceConfig.matchingBuild(for:)` — a small,
/// explicit matcher rather than a glob-library dependency.
struct ExcludeGlobMatcher: Sendable {
    /// `**/`-prefixed patterns — matched at any depth.
    private let anyDepthExact: Set<String>
    private let anyDepthSuffix: [String]
    /// Bare patterns — matched only against a direct child of the workspace root.
    private let rootOnlyExact: Set<String>
    private let rootOnlySuffix: [String]

    init(patterns: [String]) {
        var adExact: Set<String> = []
        var adSuffix: [String] = []
        var roExact: Set<String> = []
        var roSuffix: [String] = []
        for raw in patterns {
            let anyDepth = raw.hasPrefix("**/")
            var p = anyDepth ? String(raw.dropFirst(3)) : raw
            // Idiomatic trailing "directory" slash (`build/`) — strip so the name still matches.
            if p.hasSuffix("/") { p = String(p.dropLast()) }
            // A remaining path separator means a path-relative glob — out of scope; skip it.
            guard !p.isEmpty, !p.contains("/") else { continue }
            if p.hasPrefix("*.") {
                let suffix = String(p.dropFirst(1))   // "*.log" -> ".log"
                if anyDepth { adSuffix.append(suffix) } else { roSuffix.append(suffix) }
            } else if anyDepth {
                adExact.insert(p)
            } else {
                roExact.insert(p)
            }
        }
        self.anyDepthExact = adExact
        self.anyDepthSuffix = adSuffix
        self.rootOnlyExact = roExact
        self.rootOnlySuffix = roSuffix
    }

    /// True if `name` (an entry's leaf name) matches any configured exclude pattern.
    /// `isRootChild` marks a direct child of the workspace root: bare patterns (VS Code's
    /// root-anchored form) match only there, while `**/`-prefixed patterns match at any depth.
    func matches(name: String, isRootChild: Bool) -> Bool {
        if anyDepthExact.contains(name) { return true }
        if anyDepthSuffix.contains(where: { name.hasSuffix($0) }) { return true }
        guard isRootChild else { return false }
        if rootOnlyExact.contains(name) { return true }
        return rootOnlySuffix.contains { name.hasSuffix($0) }
    }
}
