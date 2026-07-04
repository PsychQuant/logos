import Foundation
import Observation
import os

/// The shared, credential-free account registry (merge-multistats-into-logos).
///
/// Persists the account list — and ONLY the account list — in a JSON index
/// file at the Logos accounts root, so the Logos app and the standalone
/// viewer observe one authoritative list. Launcher state (active selection,
/// re-auth nudges) is deliberately NOT here: it stays app-local.
///
/// Writes are atomic (temp-file-plus-rename via `.atomic`) and happen only on
/// explicit user mutations — create/rename/remove — which are rare and
/// human-paced, so last-write-wins across processes is acceptable by design.
@Observable
@MainActor
public final class AccountRegistry {

    /// The default shared index location: `~/.logos/accounts/index.json`.
    public static func defaultIndexFileURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        AccountsRoot.url(home: home).appendingPathComponent("index.json")
    }

    public private(set) var accounts: [Account]

    private let indexFileURL: URL
    private let fileManager: FileManager
    private static let log = Logger(subsystem: "app.getlogos.logos", category: "account-registry")

    /// On-disk shape. `version` gates future format evolution; nothing beyond
    /// the account list may live here ("Active selection stays out of the
    /// shared registry").
    private struct IndexFile: Codable {
        var version: Int
        var accounts: [Account]
    }

    /// The UserDefaults key the pre-registry Logos app stored its account list
    /// under. Read-fallback only during migration — never written or deleted.
    static let legacyAccountsKey = "logos.accounts"

    /// - Parameter legacyDefaults: the UserDefaults domain holding the
    ///   pre-registry account list (`logos.accounts`). Pass the Logos app's
    ///   defaults to enable the one-time migration; leave nil (the standalone
    ///   viewer, tests) to skip it — the legacy data lives in the Logos app's
    ///   per-app domain and is meaningless anywhere else.
    public init(
        indexFileURL: URL = AccountRegistry.defaultIndexFileURL(),
        fileManager: FileManager = .default,
        legacyDefaults: UserDefaults? = nil
    ) {
        self.indexFileURL = indexFileURL
        self.fileManager = fileManager
        self.accounts = Self.load(from: indexFileURL, fileManager: fileManager)

        // One-time migration ("Legacy per-app account data migrates
        // non-destructively"): only when the index file is absent, and only
        // read the legacy key — a failed decode leaves everything untouched.
        if !fileManager.fileExists(atPath: indexFileURL.path),
           let legacyData = legacyDefaults?.data(forKey: Self.legacyAccountsKey) {
            // The legacy store encoded with JSONEncoder's DEFAULT date strategy
            // (epoch-reference double), not the index file's ISO-8601.
            if let legacy = try? JSONDecoder().decode([Account].self, from: legacyData) {
                accounts = legacy
                do {
                    try save()
                } catch {
                    Self.log.notice("legacy migration decoded but index save failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                Self.log.notice("legacy account data undecodable — starting empty, legacy data preserved")
            }
        }

        // #56: enforce the system-default invariant (at most one, fixed id) on load.
        normalize()
    }

    // MARK: - Mutations (each persists immediately)

    /// Create a new account. Registry-only: no directory is created here —
    /// materializing the config dir is the launcher's job (#34).
    @discardableResult
    public func create(label: String) throws -> Account {
        let account = Account(label: try Account.validate(label: label))
        try add(account)
        return account
    }

    /// Register a pre-constructed account. This is the launcher's creation
    /// path: the caller materializes the config dir BEFORE registering, so a
    /// directory failure never leaves a registered-but-dirless account.
    /// Validates exactly like `create`.
    public func add(_ account: Account) throws {
        let trimmed = try Account.validate(label: account.label)
        // #56: label uniqueness applies to ISOLATED accounts only. The
        // system-default's identity is its fixed id (Account.systemDefaultID),
        // so a "Main" system-default may coexist with an isolated "Main".
        // System-default singleton-ness is enforced by the caller's guard +
        // load-time `normalize()`, not by label-dedup here.
        if !account.isSystemDefault, accounts.contains(where: { $0.label == trimmed }) {
            throw Account.ValidationError.duplicateLabel
        }
        accounts.append(account)
        try save()
    }

    /// #56: enforce "at most one system-default" + a stable fixed id for it.
    /// Keeps the earliest-`createdAt` system-default (migrating its id to
    /// `Account.systemDefaultID` if it's a legacy UUID), demotes any extras to
    /// isolated (non-destructive — keeps their id + dir). Idempotent + persists
    /// ONLY when it actually changed something, so a clean 0/1 index is untouched.
    private func normalize() {
        let systemDefaultIdxs = accounts.indices.filter { accounts[$0].isSystemDefault }
        guard !systemDefaultIdxs.isEmpty else { return }

        // Canonical = earliest createdAt; id as a deterministic tiebreak.
        let canonical = systemDefaultIdxs.min {
            (accounts[$0].createdAt, accounts[$0].id) < (accounts[$1].createdAt, accounts[$1].id)
        }!

        var changed = false
        for idx in systemDefaultIdxs {
            let acc = accounts[idx]
            if idx == canonical {
                if acc.id != Account.systemDefaultID {   // migrate legacy UUID → fixed id
                    accounts[idx] = Account(id: Account.systemDefaultID, label: acc.label,
                                            createdAt: acc.createdAt, isSystemDefault: true)
                    changed = true
                }
            } else {                                     // demote extra → isolated (keep id + dir)
                accounts[idx] = Account(id: acc.id, label: acc.label,
                                        createdAt: acc.createdAt, isSystemDefault: false)
                changed = true
            }
        }
        guard changed else { return }
        do { try save() } catch {
            Self.log.notice("normalize save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rename preserves the account id (the config-dir key) and createdAt, so
    /// it never moves the config dir or invalidates a login.
    public func rename(accountId: String, to newLabel: String) throws {
        let trimmed = try Account.validate(label: newLabel)
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        if accounts.contains(where: { $0.id != accountId && $0.label == trimmed }) {
            throw Account.ValidationError.duplicateLabel
        }
        let old = accounts[idx]
        // #54 verify B1: thread isSystemDefault — omitting it lets the memberwise
        // default (false) win, silently de-systeming the main account (flipping
        // spawnConfigDir nil→dir and losing the reused ~/.claude login).
        accounts[idx] = Account(id: old.id, label: trimmed, createdAt: old.createdAt,
                                isSystemDefault: old.isSystemDefault)
        try save()
    }

    public func remove(accountId: String) {
        accounts.removeAll { $0.id == accountId }
        do {
            try save()
        } catch {
            // Removal already succeeded in memory; a failed persist must not be
            // silent — surface it in the log so a stale index is explainable.
            Self.log.notice("account index save failed after remove: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Persistence

    private static func load(from url: URL, fileManager: FileManager) -> [Account] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(IndexFile.self, from: data).accounts
        } catch {
            log.notice("account index unreadable — starting empty, file preserved: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(IndexFile(version: 1, accounts: accounts))
        try fileManager.createDirectory(
            at: indexFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: indexFileURL, options: .atomic)
    }
}
