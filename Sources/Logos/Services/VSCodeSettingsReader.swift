import Foundation

/// The seam for a workspace folder's `.vscode/settings.json` (#96). This change adds the
/// **structure only**: the file is parsed so its keys are visible, but Logos interprets
/// **zero** of them as behavior (YAGNI — a later change gives specific keys meaning). The
/// tree walk still skips the `.vscode` directory (`WorkspaceLoader.skipNames`), so nothing
/// about `.vscode` is surfaced or acted on yet; this reader is where that will land.
public enum VSCodeSettingsReader {

    /// A parsed-but-uninterpreted view of `.vscode/settings.json`. `presentKeys` are the raw
    /// keys found; `honoredKeys` are the ones Logos treats as behavior — **empty** in this
    /// change (the zero-keys-honored contract).
    public struct Settings: Equatable, Sendable {
        public let presentKeys: [String]

        public init(presentKeys: [String] = []) {
            self.presentKeys = presentKeys
        }

        /// The keys Logos interprets as behavior. Empty until a follow-up change maps
        /// specific VS Code settings onto Logos concepts.
        public var honoredKeys: [String] { [] }

        /// The result when there is nothing to read (absent / malformed settings).
        public static let neutral = Settings(presentKeys: [])
    }

    /// Read `<folderPath>/.vscode/settings.json`. Absent / unreadable / malformed all return
    /// `.neutral`; a valid object returns its keys as `presentKeys` (none interpreted).
    public static func read(folderPath: String, fileManager: FileManager = .default) -> Settings {
        let path = "\(folderPath)/.vscode/settings.json"
        guard
            let data = fileManager.contents(atPath: path),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .neutral }
        return Settings(presentKeys: Array(obj.keys))
    }
}
