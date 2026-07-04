import Foundation

/// Single source of truth for the Logos accounts root
/// (`~/.logos/accounts`) — the config-dir convention that keys per-account
/// `CLAUDE_CONFIG_DIR` isolation, discovery scanning, and the shared
/// registry index. Every path under the accounts root SHALL derive from
/// here; deriving it anywhere else re-splits the convention the
/// merge-multistats-into-logos change consolidated.
public enum AccountsRoot {
    public static func url(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".logos/accounts")
    }
}
