import Foundation

/// Reader for a workspace folder's `.vscode/settings.json` (#96 seam, #97 Slice 1).
///
/// #96 landed this as a **structure-only, zero-key** seam: the file was parsed so its keys
/// were visible, but Logos interpreted none of them. #97 Slice 1 gives the **first** key
/// meaning — `files.exclude` — whose enabled glob patterns are surfaced as `filesExclude` and
/// threaded into the tree walk so Logos hides the same entries VS Code hides. Every other key
/// is still parsed-but-uninterpreted (`presentKeys`), pending later slices.
///
/// The tree walk still skips the `.vscode` directory itself (`WorkspaceLoader.skipNames`); this
/// reader is the deliberate, separate path that reads its contents.
public enum VSCodeSettingsReader {

    /// A parsed view of `.vscode/settings.json`. `presentKeys` are the raw keys found;
    /// `filesExclude` are the enabled `files.exclude` globs (#97 Slice 1); `honoredKeys` reports
    /// which keys Logos actually acts on.
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
        /// enabled pattern (#97 Slice 1); other keys remain unhonored pending later slices.
        public var honoredKeys: [String] {
            filesExclude.isEmpty ? [] : ["files.exclude"]
        }

        /// The result when there is nothing to read (absent / malformed settings).
        public static let neutral = Settings(presentKeys: [], filesExcludeMap: [:])
    }

    /// Read `<folderPath>/.vscode/settings.json`. Absent / unreadable / malformed all return
    /// `.neutral`; a valid object returns its keys as `presentKeys` and its enabled
    /// `files.exclude` patterns as `filesExclude`. Lenient — never throws.
    public static func read(folderPath: String, fileManager: FileManager = .default) -> Settings {
        let path = "\(folderPath)/.vscode/settings.json"
        guard
            let data = fileManager.contents(atPath: path),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .neutral }
        return Settings(presentKeys: Array(obj.keys),
                        filesExcludeMap: filesExcludeMap(from: obj["files.exclude"]))
    }

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

    /// True only for a genuine JSON boolean `true`. `JSONSerialization` decodes JSON booleans to
    /// `CFBoolean` and integers to `CFNumber`, but `NSNumber(1) as? Bool` is `true` — so a plain
    /// `as? Bool` would wrongly accept an integer `1` as enabled. Gate on the `CFBoolean` type id
    /// to reject numbers (and everything else), keeping the "only literal `true`" contract honest.
    private static func isEnabled(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue
    }
}
