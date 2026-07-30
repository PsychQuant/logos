import Foundation

/// Locates the default gateway command: the newest `claude-hot-limit`
/// rate-limit proxy installed in the Claude Code plugin cache.
///
/// Pure apart from the injected `FileManager`, so the version-ordering rule is
/// provable without touching the real plugin cache.
public enum GatewayCommandResolver {

    /// Directory holding one subdirectory per installed plugin version.
    public static func pluginVersionsRoot(home: URL) -> URL {
        home.appending(path: ".claude/plugins/cache/claude-hot-limit/claude-hot-limit")
    }

    /// Version directory names ordered NEWEST FIRST, comparing each dot-separated
    /// component NUMERICALLY.
    ///
    /// Lexicographic ordering is wrong here and not hypothetically so: the
    /// maintainer's machine holds both `1.9.0` and `1.19.0`, and a string sort puts
    /// `1.9.0` on top — quietly selecting a proxy several releases behind. Names
    /// that are not all-numeric dot-separated components are skipped.
    public static func versionsNewestFirst(in names: [String]) -> [String] {
        names
            .compactMap { name -> (key: [Int], name: String)? in
                let parts = name.split(separator: ".", omittingEmptySubsequences: false)
                guard !parts.isEmpty else { return nil }
                var key: [Int] = []
                for part in parts {
                    guard let value = Int(part), value >= 0 else { return nil }
                    key.append(value)
                }
                return (key, name)
            }
            .sorted { $1.key.lexicographicallyPrecedes($0.key) }
            .map(\.name)
    }

    /// Highest version among directory names, or nil when none parse.
    public static func highestVersion(in names: [String]) -> String? {
        versionsNewestFirst(in: names).first
    }

    /// Full argv for the default gateway command, or nil when no installed version
    /// carries a readable proxy script.
    ///
    /// Walks versions newest-first and returns the first that actually has the
    /// script, rather than committing to the highest version outright: a
    /// half-written or partially-removed newest directory would otherwise shadow a
    /// perfectly good older install and yield no gateway at all.
    ///
    /// `nil` means "no gateway configured" — the caller's failure policy decides
    /// what that implies for the account.
    public static func resolve(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String]? {
        let root = pluginVersionsRoot(home: home)
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            GatewayLog.resolver.notice("no claude-hot-limit plugin cache found")
            return nil
        }

        for version in versionsNewestFirst(in: names) {
            let script = root.appending(path: "\(version)/proxy/rate-limit-proxy.py")
            guard fileManager.isReadableFile(atPath: script.path) else { continue }
            GatewayLog.resolver.notice(
                "resolved gateway command from version \(version, privacy: .public)"
            )
            return ["/usr/bin/env", "python3", script.path]
        }

        GatewayLog.resolver.notice("plugin cache holds no readable proxy script")
        return nil
    }
}
