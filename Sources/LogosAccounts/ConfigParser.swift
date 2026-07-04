import Foundation

/// Reads the account identity out of Claude Code's top-level config JSON.
///
/// The file lives in one of two places depending on how the account was set up:
/// - default account: sibling of the config dir (`~/.claude` → `~/.claude.json`)
/// - `CLAUDE_CONFIG_DIR` account (Logos): inside the config dir (`<dir>/.claude.json`)
public enum ConfigParser {
    /// Locates the top-level config JSON for a config dir, or nil if the
    /// account has never been initialized (shell dir).
    public static func configJSONURL(for configDir: URL, fileManager: FileManager = .default) -> URL? {
        let inside = configDir.appendingPathComponent(".claude.json")
        if fileManager.fileExists(atPath: inside.path) { return inside }
        let sibling = URL(fileURLWithPath: configDir.standardizedFileURL.path + ".json")
        if fileManager.fileExists(atPath: sibling.path) { return sibling }
        return nil
    }

    /// Parses the `oauthAccount` subset from raw config JSON data.
    public static func identity(fromConfigData data: Data) -> AccountIdentity? {
        struct TopLevel: Decodable { let oauthAccount: AccountIdentity? }
        return (try? JSONDecoder().decode(TopLevel.self, from: data))?.oauthAccount
    }

    /// Convenience: locate + read + parse for a config dir.
    public static func identity(forConfigDir configDir: URL, fileManager: FileManager = .default) -> AccountIdentity? {
        guard let url = configJSONURL(for: configDir, fileManager: fileManager),
              let data = try? Data(contentsOf: url) else { return nil }
        return identity(fromConfigData: data)
    }
}
