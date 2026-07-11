import Foundation
import os

/// Deletes per-account data directories under the Logos accounts root
/// (`~/.logos/accounts/<id>`) — the ONLY component that removes account data
/// from disk (#50). Two entry points share one guarded delete core:
///
///  - `reap(accountID:)` — remove ONE account's dir after it has been
///    unregistered (the `AccountManager.remove` disk cleanup: pre-#50 removes
///    rewrote `index.json` but never deleted the dir, orphaning it forever).
///  - `reapOrphans(liveIDs:)` — a conservative one-shot startup GC that removes
///    ONLY dirs that are BOTH absent from the live registry AND carry no claude
///    config JSON (the same "is this a real account" signal `AccountDiscovery`
///    filters on), sweeping the historical orphans left by pre-#50 removes.
///
/// Deleting account data is irreversible, so every removal is guarded twice
/// over: the resolved target must sit DIRECTLY under the accounts root and must
/// NOT be a symlink, so neither a crafted id (already format-validated by #61)
/// nor a planted link can redirect the removal outside the root. The bias is
/// deliberately toward NOT deleting — a surviving orphan is harmless cruft; a
/// wrongly-reaped live dir is data loss.
public struct AccountReaper {

    private let accountsRoot: URL
    private let fileManager: FileManager
    private static let log = Logger(subsystem: "app.getlogos.logos", category: "account-reaper")

    /// - Parameters:
    ///   - home: the home directory whose `~/.logos/accounts` root is swept.
    ///     Defaults to the current user's — injected as a temp root in tests so
    ///     the suite never touches the real accounts tree.
    ///   - fileManager: injected for tests; production uses `.default`.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.accountsRoot = AccountsRoot.url(home: home)
        self.fileManager = fileManager
    }

    /// Remove one account's data dir (`~/.logos/accounts/<id>`). Returns whether a
    /// directory was actually deleted. No-op (returns false) when the dir is
    /// absent, escapes the accounts root, or is a symlink. Callers gate this to
    /// NON-system-default accounts (`AccountManager.remove`): a system-default
    /// reuses the shared `~/.claude` and has no per-account dir to reap.
    @discardableResult
    public func reap(accountID id: String) -> Bool {
        reapDirectory(named: id)
    }

    /// One-shot startup GC. Removes every `<id>/` directly under the accounts root
    /// that is BOTH (a) absent from `liveIDs` (not a registered account) AND
    /// (b) carries no claude config JSON (`ConfigParser.configJSONURL == nil` — the
    /// AccountDiscovery "never a real, logged-in account" signal). Returns the ids
    /// reaped. Conservative by construction: a dir that is registered OR holds a
    /// config JSON is always spared, so no single stale signal can cause data loss.
    /// Idempotent — a second run finds nothing left to reap.
    @discardableResult
    public func reapOrphans(liveIDs: Set<String>) -> [String] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: accountsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var reaped: [String] = []
        for entry in entries {
            let id = entry.lastPathComponent
            // (b) registered → a real account, spare it (even an un-logged-in shell).
            guard !liveIDs.contains(id) else { continue }
            // (a) holds a config JSON → a real, logged-in account, spare it.
            let configDir = entry.appendingPathComponent(".claude")
            guard ConfigParser.configJSONURL(for: configDir, fileManager: fileManager) == nil else {
                continue
            }
            if reapDirectory(named: id) { reaped.append(id) }
        }
        if !reaped.isEmpty {
            Self.log.notice("startup GC reaped \(reaped.count, privacy: .public) orphaned account dir(s)")
        }
        return reaped
    }

    /// Shared guarded delete core. Resolves `<accountsRoot>/<name>`, confirms it is
    /// an existing DIRECTORY sitting directly under the accounts root and is NOT a
    /// symlink, then removes it. Any guard failing → no delete, returns false.
    private func reapDirectory(named name: String) -> Bool {
        let target = accountsRoot.appendingPathComponent(name)
        // Belt-and-suspenders on an irreversible op: the id is already a #61-validated
        // safe path component, but re-confirm the RESOLVED parent is still exactly the
        // accounts root — a `..`/absolute component would make it diverge — so the
        // removal can never climb out of the root. Compare standardized `.path` so a
        // trailing-slash difference can't false-negative the guard.
        let rootPath = accountsRoot.standardizedFileURL.path
        let parentPath = target.deletingLastPathComponent().standardizedFileURL.path
        guard parentPath == rootPath else {
            Self.log.notice("reap refused — resolved path escapes the accounts root")
            return false
        }
        // `attributesOfItem` is lstat-like (does NOT follow the final symlink), so a
        // symlink AT the target is detected here rather than followed into its target.
        guard let attrs = try? fileManager.attributesOfItem(atPath: target.path) else {
            return false   // absent — nothing to reap
        }
        if let type = attrs[.type] as? FileAttributeType {
            guard type == .typeDirectory else {
                // A symlink (even one pointing at a directory) or a plain file is never
                // reaped: only a genuine directory under the root is account data.
                if type == .typeSymbolicLink {
                    Self.log.notice("reap refused — target is a symlink")
                }
                return false
            }
        }
        do {
            try fileManager.removeItem(at: target)
            return true
        } catch {
            Self.log.notice("reap failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
