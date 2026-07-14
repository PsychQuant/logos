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

        /// Enabled `files.exclude` glob patterns — the keys of the `files.exclude` object whose
        /// value is exactly `true` (a `false` or a conditional `{ "when": … }` value is not
        /// enabled). Sorted for deterministic ordering. Empty when the key is absent/empty.
        public let filesExclude: [String]

        public init(presentKeys: [String] = [], filesExclude: [String] = []) {
            self.presentKeys = presentKeys
            self.filesExclude = filesExclude
        }

        /// The keys Logos interprets as behavior. `files.exclude` is honored when it has >=1
        /// enabled pattern (#97 Slice 1); other keys remain unhonored pending later slices.
        public var honoredKeys: [String] {
            filesExclude.isEmpty ? [] : ["files.exclude"]
        }

        /// The result when there is nothing to read (absent / malformed settings).
        public static let neutral = Settings(presentKeys: [], filesExclude: [])
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
        return Settings(presentKeys: Array(obj.keys), filesExclude: enabledExcludes(obj["files.exclude"]))
    }

    /// Extract the enabled patterns from a `files.exclude` value. VS Code's shape is
    /// `{ "<glob>": <bool | { when: … }> }`; only a value of literal `true` is enabled — a
    /// `false` (explicitly un-hidden) or a conditional object is conservatively left unhonored.
    private static func enabledExcludes(_ raw: Any?) -> [String] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.compactMap { key, value in
            isEnabled(value) ? key : nil
        }.sorted()
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
