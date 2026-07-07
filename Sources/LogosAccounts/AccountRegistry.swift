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

    /// #57 F4: whether the load-time `normalize()` repair was persisted to disk.
    /// `AccountManager` reads this to avoid persisting a healed active id against an
    /// un-persisted repair (true = on disk / no repair needed; false = repaired in
    /// memory but save failed).
    public private(set) var normalizeDidPersist: Bool = true

    /// #58: ids whose OWNERSHIP became ambiguous during the last load-time
    /// `normalize()` repair — each was some account's id that phase 2 took away
    /// (that account got a fresh UUID). The old id may STILL resolve afterwards
    /// (to the system-default or the first occupant), so a stored active
    /// selection pointing at one of these is untrustworthy: `AccountManager`
    /// treats it as needing heal, exactly like a dangling id. Session-scoped —
    /// set once by init's normalize, regardless of whether the repair persisted
    /// (the in-memory ownership changed either way).
    public private(set) var reassignedIDs: Set<String> = []

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
        // #57 verify C: a migration whose index save fails leaves the list in memory
        // only — that MUST fold into `normalizeDidPersist`, so track it here.
        var migrationSaveFailed = false
        if !fileManager.fileExists(atPath: indexFileURL.path),
           let legacyData = legacyDefaults?.data(forKey: Self.legacyAccountsKey) {
            // The legacy store encoded with JSONEncoder's DEFAULT date strategy
            // (epoch-reference double), not the index file's ISO-8601.
            if let legacy = try? JSONDecoder().decode([Account].self, from: legacyData) {
                accounts = legacy
                do {
                    try save()
                } catch {
                    migrationSaveFailed = true
                    Self.log.notice("legacy migration decoded but index save failed: \(error.localizedDescription, privacy: .private)")
                }
            } else {
                Self.log.notice("legacy account data undecodable — starting empty, legacy data preserved")
            }
        }

        // #56/#57: enforce the system-default + uniqueness invariants on load; capture
        // whether the repair persisted (F4) for AccountManager to coordinate. #57
        // verify C: an un-persisted migration forces one more save attempt inside
        // normalize, so the returned flag reflects the TRUE on-disk state (a normalize
        // save that succeeds heals the failed migration save — it writes the whole index).
        self.normalizeDidPersist = normalize(forceSave: migrationSaveFailed)
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
        // #61: the id is a config-dir path component — malformed ids (traversal,
        // control chars) are rejected at the gate, not just repaired at next load.
        guard Account.isValidID(account.id) else {
            throw Account.ValidationError.invalidID
        }
        // #57 F1: global id-uniqueness — no two accounts may share an id.
        if accounts.contains(where: { $0.id == account.id }) {
            throw Account.ValidationError.duplicateID
        }
        // #57 F2: at most one system-default account (the load-time normalize is the
        // recovery net; this is the mutation-time gate that keeps the invariant live).
        if account.isSystemDefault, accounts.contains(where: { $0.isSystemDefault }) {
            throw Account.ValidationError.duplicateSystemDefault
        }
        // #57 round-2 verify #1: reserved-id OWNERSHIP is a mutation-time gate too —
        // an isolated account may not take the reserved id, and a system-default may
        // not take any other. Previously only normalize() repaired this at next load,
        // so a mis-constructed account lived in memory for the whole session.
        if account.isSystemDefault != (account.id == Account.systemDefaultID) {
            throw Account.ValidationError.reservedID
        }
        // #56 B1: label uniqueness applies to ISOLATED accounts only — filter BOTH the
        // new account (skip for system-default) AND the existing set (isolated only), so
        // a "Main" system-default coexists with an isolated "Main" in either order.
        if !account.isSystemDefault, accounts.contains(where: { !$0.isSystemDefault && $0.label == trimmed }) {
            throw Account.ValidationError.duplicateLabel
        }
        // #57: transactional — rolls back the append if save fails (generalizes #56 C2).
        try mutate { accounts.append(account) }
    }

    /// #57: run a mutation transactionally — snapshot, mutate, persist, and roll
    /// back the snapshot if `body` OR `save()` throws, so a failed mutation or
    /// persist never leaves the in-memory list diverged from disk. Generalizes
    /// #56's add-only rollback (C2) to every user mutation path (add / rename /
    /// remove). #57 round-2 verify #3: `body` runs INSIDE the do-catch — the
    /// rollback guarantee holds even for a future throwing body, not just the
    /// current non-throwing closures. NOT used by `normalize`, which keeps its
    /// repaired state in memory + signals via its Bool return.
    private func mutate(_ body: () throws -> Void) throws {
        let snapshot = accounts
        do {
            try body()
            try save()
        } catch {
            accounts = snapshot
            throw error
        }
    }

    /// #56/#57: enforce "at most one system-default" + a stable fixed id + global
    /// id/label uniqueness on load. Keeps the earliest-`createdAt` system-default
    /// (migrating its id to `Account.systemDefaultID`), demotes extras to isolated
    /// (uniquified label if they'd collide). #57 verify B: a second pass then
    /// enforces global id uniqueness UNCONDITIONALLY — the reserved id belongs to
    /// the system-default alone, and every other id may appear once — so a crafted
    /// index can't keep a duplicate just because the canonical needed no migration
    /// or no system-default exists at all. Idempotent — a clean index isn't re-saved.
    /// #57 F4: returns whether the repair is PERSISTED (true = on disk / no-op;
    /// false = repaired in memory but save failed). Unlike `mutate`, normalize keeps
    /// its in-memory repair on save failure — the clean state is still correct for
    /// this session — and signals the caller via this Bool.
    /// #57 verify C: `forceSave` saves even when nothing changed — the init passes it
    /// when a legacy-migration save failed, so the in-memory list gets one more write
    /// attempt and the return value reports the true on-disk state either way.
    @discardableResult
    private func normalize(forceSave: Bool = false) -> Bool {
        var changed = false

        // Phase 0 (#61): id FORMAT. A malformed id (traversal, control chars, empty,
        // over-long) is a security problem the moment it's used as a path component
        // (`configDirPath` → `CLAUDE_CONFIG_DIR`), so it's repaired before anything
        // else keys off ids. Fresh ids avoid every current id. The OLD malformed id
        // is NOT recorded in `reassignedIDs`: nothing can hold it afterwards
        // (dangling), so the existing active==nil heal covers a stored selection.
        var allIDs = Set(accounts.map(\.id))
        for idx in accounts.indices where !Account.isValidID(accounts[idx].id) {
            let acc = accounts[idx]
            var fresh = UUID().uuidString
            while allIDs.contains(fresh) { fresh = UUID().uuidString }
            allIDs.insert(fresh)
            accounts[idx] = Account(id: fresh, label: acc.label,
                                    createdAt: acc.createdAt, isSystemDefault: acc.isSystemDefault)
            changed = true
        }

        // Phase 1: at most one system-default, and it holds the reserved fixed id.
        let systemDefaultIdxs = accounts.indices.filter { accounts[$0].isSystemDefault }
        if !systemDefaultIdxs.isEmpty {
            // Canonical = earliest createdAt; id as a deterministic tiebreak.
            let canonical = systemDefaultIdxs.min {
                (accounts[$0].createdAt, accounts[$0].id) < (accounts[$1].createdAt, accounts[$1].id)
            }!
            for idx in systemDefaultIdxs {
                let acc = accounts[idx]
                if idx == canonical {
                    if acc.id != Account.systemDefaultID {   // migrate legacy UUID → fixed id
                        accounts[idx] = Account(id: Account.systemDefaultID, label: acc.label,
                                                createdAt: acc.createdAt, isSystemDefault: true)
                        changed = true
                    }
                } else {                                     // demote extra → isolated
                    // #57 F3: uniquify the label if it collides with an existing isolated
                    // one. The id is kept as-is — phase 2 re-ids it if it collides (which
                    // subsumes #56 B2's demoted-extra-holds-the-fixed-id special case).
                    let demotedLabel = uniqueIsolatedLabel(acc.label, excludingIndex: idx)
                    accounts[idx] = Account(id: acc.id, label: demotedLabel,
                                            createdAt: acc.createdAt, isSystemDefault: false)
                    changed = true
                }
            }
        }

        // Phase 2 (#57 verify B): global id uniqueness. The system-default owns its
        // (fixed) id outright — seeded first so a squatter earlier in the array can't
        // win the dedup — the reserved id may belong ONLY to the system-default, and
        // any other id may appear once: first occurrence keeps it, later ones get a
        // fresh UUID. (Re-idding an account orphans its config dir, but every such id
        // is crafted/corrupt data — `add` F1 rejects duplicates at mutation time.)
        var seen = Set<String>()
        // #57 round-2 verify #4: fresh ids must avoid EVERY current id (visited or
        // not) plus previously generated ones — `seen` alone can't see ids later in
        // the array, so a fresh UUID could in principle re-collide. `taken` closes
        // that (astronomically unlikely) hole outright.
        var taken = Set(accounts.map(\.id))
        // #58: every id phase 2 takes AWAY from an account has ambiguous ownership
        // afterwards (it may still resolve — to whoever kept it). Collect them so
        // AccountManager can distrust a stored active selection pointing at one.
        var reassigned = Set<String>()
        if let sd = accounts.first(where: { $0.isSystemDefault }) {
            seen.insert(sd.id)
        }
        for idx in accounts.indices where !accounts[idx].isSystemDefault {
            let acc = accounts[idx]
            if seen.contains(acc.id) || acc.id == Account.systemDefaultID {
                var fresh = UUID().uuidString
                while taken.contains(fresh) { fresh = UUID().uuidString }
                taken.insert(fresh)
                reassigned.insert(acc.id)
                accounts[idx] = Account(id: fresh, label: acc.label,
                                        createdAt: acc.createdAt, isSystemDefault: false)
                changed = true
            }
            seen.insert(accounts[idx].id)
        }
        // #58: recorded regardless of the save outcome below — the in-memory
        // ownership changed either way. (Phase-1 canonical migration old-ids become
        // DANGLING, covered by the existing heal. Demotes keep their id at the
        // demote step itself — but phase 2 re-checks every final id, so a demoted
        // account still holding a colliding/reserved id IS evicted and recorded here.)
        reassignedIDs = reassigned

        // Phase 3 (#59): label invariants. Labels from DISK bypass `Account.validate`
        // (init(from:) doesn't trim), so re-impose the mutation-path bounds here —
        // trim (incl. newlines, which only the decode path can carry), placeholder an
        // empty label, clamp to 30 chars — then uniquify duplicate ISOLATED labels.
        // First occurrence in array order keeps its label (the same deterministic
        // tie-break as the phase-2 id sweep; note phase 1's demote uniquify instead
        // defers to ANY existing isolated label regardless of position — both are
        // recovery policies, not intent reconstruction). The system-default is exempt
        // from uniqueness: a system-default "Main" coexists with an isolated "Main"
        // (#56 B1). Cleanup runs FIRST because trimming itself can create a duplicate.
        // Labels are cosmetic — config dirs key off `id` — so the repair is identity-safe.
        //
        // #59 verify (blocking): `changed` reflects the NET label change of the whole
        // pass, compared at the end — at an exact-cap collision the cleanup clamp and
        // the uniquify suffix undo each other back to the stored bytes, and a per-step
        // flag would fire save() on EVERY load forever. Net comparison converges: the
        // repaired file is written once, then never rewritten.
        let labelsBefore = accounts.map(\.label)
        for idx in accounts.indices {
            let acc = accounts[idx]
            var label = acc.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty { label = "(unnamed)" }
            if label.count > 30 { label = String(label.prefix(30)) }
            if label != acc.label {
                accounts[idx] = Account(id: acc.id, label: label,
                                        createdAt: acc.createdAt, isSystemDefault: acc.isSystemDefault)
            }
        }
        // #59 verify (O(N²)): incremental sets instead of a per-collision rescan of the
        // whole list — a crafted index with thousands of same-labeled accounts must not
        // hang the @MainActor init. `used` holds every isolated label still assigned
        // (visited or not) plus generated candidates; `seenFirst` holds labels already
        // claimed by an earlier occurrence.
        var used = Set<String>()
        for idx in accounts.indices where !accounts[idx].isSystemDefault {
            used.insert(accounts[idx].label)
        }
        var seenFirst = Set<String>()
        for idx in accounts.indices where !accounts[idx].isSystemDefault {
            let acc = accounts[idx]
            if seenFirst.contains(acc.label) {
                var candidate = "\(acc.label) (recovered)"
                var n = 2
                while used.contains(candidate) {
                    candidate = "\(acc.label) (recovered \(n))"
                    n += 1
                }
                used.insert(candidate)
                accounts[idx] = Account(id: acc.id, label: candidate,
                                        createdAt: acc.createdAt, isSystemDefault: false)
                seenFirst.insert(candidate)
            } else {
                seenFirst.insert(acc.label)
            }
        }
        if accounts.map(\.label) != labelsBefore {
            changed = true
        }

        guard changed || forceSave else { return true }
        do {
            try save()
            return true
        } catch {
            // #56 B5: .private — localizedDescription may echo the index path (username).
            Self.log.notice("normalize save failed: \(error.localizedDescription, privacy: .private)")
            return false   // #57 F4: repaired in memory, not persisted
        }
    }

    /// #57 F3: a label unique among EXISTING isolated accounts (excluding the account
    /// at `excludingIndex`), suffixing "(recovered)" / "(recovered N)" on collision.
    /// Used by phase 1's demote branch only (small N per load) — phase 3's uniquify
    /// sweep uses its own incremental sets instead (#59 verify, O(N²) finding).
    private func uniqueIsolatedLabel(_ label: String, excludingIndex: Int) -> String {
        let taken = Set(accounts.indices
            .filter { $0 != excludingIndex && !accounts[$0].isSystemDefault }
            .map { accounts[$0].label })
        guard taken.contains(label) else { return label }
        var candidate = "\(label) (recovered)"
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(label) (recovered \(n))"
            n += 1
        }
        return candidate
    }

    /// Rename preserves the account id (the config-dir key) and createdAt, so
    /// it never moves the config dir or invalidates a login.
    public func rename(accountId: String, to newLabel: String) throws {
        let trimmed = try Account.validate(label: newLabel)
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        let old = accounts[idx]
        // #56 verify C3: coexistence holds under rename too — a system-default may take
        // ANY label; an isolated account collides only with OTHER isolated accounts.
        // (B1 fixed add()/createAccount() but missed rename — round-2 DA finding.)
        if !old.isSystemDefault, accounts.contains(where: { $0.id != accountId && !$0.isSystemDefault && $0.label == trimmed }) {
            throw Account.ValidationError.duplicateLabel
        }
        // #54 verify B1: thread isSystemDefault — omitting it lets the memberwise
        // default (false) win, silently de-systeming the main account (flipping
        // spawnConfigDir nil→dir and losing the reused ~/.claude login).
        // #57: transactional — roll back if save fails (parity with add/remove).
        try mutate {
            accounts[idx] = Account(id: old.id, label: trimmed, createdAt: old.createdAt,
                                    isSystemDefault: old.isSystemDefault)
        }
    }

    /// #57: transactional — a failed persist rolls back, so remove never leaves
    /// the in-memory list diverged from disk (parity with add/rename).
    /// #57 verify A: throwing — the failure PROPAGATES (not swallowed) so callers
    /// can keep their own state (active selection, live-401 flags) in sync with
    /// the rolled-back list instead of desyncing against a phantom removal.
    public func remove(accountId: String) throws {
        // #57 round-2 verify #5: a nonexistent id is a no-op — don't touch the disk
        // (parity with rename's guard; a broken disk must not fail a vacuous remove).
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        try mutate { accounts.removeAll { $0.id == accountId } }
    }

    // MARK: - Persistence

    /// #61: caps on the attacker-writable index. Beyond either cap the file is
    /// treated exactly like a corrupt one — load empty, preserve the bytes as
    /// evidence. 500 accounts × ~200 bytes ≈ 100 KB, so 1 MB leaves ~10× headroom
    /// over any legitimate index.
    static let maxIndexBytes = 1_048_576
    static let maxAccounts = 500

    private static func load(from url: URL, fileManager: FileManager) -> [Account] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= maxIndexBytes else {
                log.notice("account index exceeds size cap — starting empty, file preserved")
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(IndexFile.self, from: data).accounts
            guard decoded.count <= maxAccounts else {
                log.notice("account index exceeds account-count cap — starting empty, file preserved")
                return []
            }
            return decoded
        } catch {
            log.notice("account index unreadable — starting empty, file preserved: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(IndexFile(version: 1, accounts: accounts))
        // #61: restrictive modes, defense-in-depth. `attributes` applies only to
        // directories this call CREATES — pre-existing dirs keep their mode (no
        // forced migration).
        try fileManager.createDirectory(
            at: indexFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: indexFileURL, options: .atomic)
        // #61: the atomic replace inherits the temp file's permissions — re-apply
        // each save. Best-effort by design: the write above already succeeded, and
        // throwing here would make `mutate` roll back memory against a disk that
        // DID change (breaking the "rollback ⇒ disk unchanged" invariant).
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexFileURL.path)
        } catch {
            Self.log.notice("index permission set failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
