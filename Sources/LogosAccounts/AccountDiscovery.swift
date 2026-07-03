import Foundation

/// Discovers Claude Code accounts on this machine: the default `~/.claude`
/// plus Logos per-account config dirs (`~/.logos/accounts/<uuid>/.claude`).
///
/// Shell dirs left behind by never-logged-in accounts (no top-level config
/// JSON — 50+ of them observed in practice) are filtered out.
public enum AccountDiscovery {
    public static func discover(home: URL) -> [Account] {
        let fm = FileManager.default
        var accounts: [Account] = []

        let defaultDir = home.appendingPathComponent(".claude")
        if ConfigParser.configJSONURL(for: defaultDir, fileManager: fm) != nil {
            accounts.append(Account(
                configDir: defaultDir,
                isDefault: true,
                identity: ConfigParser.identity(forConfigDir: defaultDir, fileManager: fm)))
        }

        let logosRoot = home.appendingPathComponent(".logos/accounts")
        let entries = (try? fm.contentsOfDirectory(
            at: logosRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let configDir = entry.appendingPathComponent(".claude")
            guard ConfigParser.configJSONURL(for: configDir, fileManager: fm) != nil else { continue }
            accounts.append(Account(
                configDir: configDir,
                isDefault: false,
                identity: ConfigParser.identity(forConfigDir: configDir, fileManager: fm)))
        }

        return accounts
    }
}
