import Foundation
import Testing
@testable import LogosAccounts

/// Registry persistence + mutation contract (merge-multistats-into-logos,
/// spec account-registry). Every test runs against a temp index file — the
/// shared file IS the behavior under test, so no in-memory fake here.
@Suite("AccountRegistry")
struct AccountRegistryTests {

    private func tempIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-tests-\(UUID().uuidString)")
            .appendingPathComponent("index.json")
    }

    /// #57: write a raw index file directly, bypassing `add()` — simulates a corrupt /
    /// externally-edited index. `add()` now enforces invariants it cannot itself produce
    /// (two system-defaults, a duplicate id), so a corrupt state must be injected on disk.
    private func writeCorruptIndex(
        _ rows: [(id: String, label: String, epoch: TimeInterval, sd: Bool)], to url: URL
    ) throws {
        let iso = ISO8601DateFormatter()
        let entries = rows.map {
            "{\"id\":\"\($0.id)\",\"label\":\"\($0.label)\",\"createdAt\":\"\(iso.string(from: Date(timeIntervalSince1970: $0.epoch)))\",\"isSystemDefault\":\($0.sd)}"
        }.joined(separator: ",")
        let json = "{\"version\":1,\"accounts\":[\(entries)]}"
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    // MARK: - "Account list persists in a shared file-based index"

    @Test("create/rename/remove round-trips through the index file")
    @MainActor func roundTrip() throws {
        let url = tempIndexURL()

        let registry = AccountRegistry(indexFileURL: url)
        let work = try registry.create(label: "work")
        let personal = try registry.create(label: "personal")
        try registry.rename(accountId: personal.id, to: "Personal 2")
        try registry.remove(accountId: work.id)

        // A second instance on the same file = "the other executable".
        let reloaded = AccountRegistry(indexFileURL: url)
        #expect(reloaded.accounts.count == 1)
        let survivor = try #require(reloaded.accounts.first)
        #expect(survivor.id == personal.id)
        #expect(survivor.label == "Personal 2")
        #expect(abs(survivor.createdAt.timeIntervalSince(personal.createdAt)) < 1)
    }

    @Test("index file carries version 1 and only the account list")
    @MainActor func fileShape() throws {
        let url = tempIndexURL()
        let registry = AccountRegistry(indexFileURL: url)
        try registry.create(label: "work")
        try registry.create(label: "personal")

        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        // Active selection (or anything else) must never leak into the shared
        // index — "Active selection stays out of the shared registry".
        #expect(Set(object.keys) == ["version", "accounts"])

        let accounts = try #require(object["accounts"] as? [[String: Any]])
        #expect(accounts.count == 2)
        for entry in accounts {
            #expect(entry["id"] is String)
            #expect(entry["label"] is String)
            // ISO-8601 string, not a numeric epoch.
            let createdAt = try #require(entry["createdAt"] as? String)
            #expect(createdAt.contains("T"))
        }
    }

    @Test("save creates the parent directory when missing")
    @MainActor func createsParentDirectory() throws {
        let url = tempIndexURL()   // parent dir does not exist yet
        let registry = AccountRegistry(indexFileURL: url)
        try registry.create(label: "work")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("absent index file loads as empty")
    @MainActor func absentFile() {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        #expect(registry.accounts.isEmpty)
    }

    // MARK: - "Registry mutations validate labels"

    @Test("empty label is rejected")
    @MainActor func emptyLabel() {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        #expect(throws: Account.ValidationError.emptyLabel) {
            try registry.create(label: "   ")
        }
    }

    @Test("31-character label is rejected")
    @MainActor func labelTooLong() {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        #expect(throws: Account.ValidationError.labelTooLong) {
            try registry.create(label: String(repeating: "x", count: 31))
        }
    }

    @Test("duplicate label on create is rejected")
    @MainActor func duplicateCreate() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.create(label: "work")
        #expect(throws: Account.ValidationError.duplicateLabel) {
            try registry.create(label: "work")
        }
    }

    @Test("renaming an account to its own label succeeds")
    @MainActor func ownLabelRename() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        let account = try registry.create(label: "work")
        try registry.rename(accountId: account.id, to: "work")
        #expect(registry.accounts.first?.label == "work")
    }

    @Test("renaming to another account's label is rejected")
    @MainActor func duplicateRename() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.create(label: "work")
        let personal = try registry.create(label: "personal")
        #expect(throws: Account.ValidationError.duplicateLabel) {
            try registry.rename(accountId: personal.id, to: "work")
        }
    }

    @Test("rename preserves id and createdAt")
    @MainActor func renamePreservesIdentity() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        let account = try registry.create(label: "work")
        try registry.rename(accountId: account.id, to: "Work 2")
        let renamed = try #require(registry.accounts.first)
        #expect(renamed.id == account.id)
        #expect(renamed.createdAt == account.createdAt)
        #expect(renamed.label == "Work 2")
    }

    // MARK: - System-default hardening (#56)

    // #56 gap 1: label uniqueness applies to isolated accounts only — a
    // system-default "Main" coexists with an isolated "Main" (identity is the id).
    @Test("a system-default coexists with an isolated account of the same label (#56)")
    @MainActor func systemDefaultCoexistsWithIsolatedSameLabel() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.add(Account(label: "Main"))                                        // isolated
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))  // system-default
        #expect(registry.accounts.count == 2)
        #expect(registry.accounts.filter(\.isSystemDefault).count == 1)
    }

    // #56 gap 2: load-time normalize enforces "at most one system-default" —
    // keep earliest createdAt, demote the rest to isolated.
    @Test("normalize demotes ≥2 persisted system-defaults to one (earliest kept) (#56)")
    @MainActor func normalizeDemotesExtraSystemDefaults() throws {
        let url = tempIndexURL()
        // #57: two system-defaults can only exist via a corrupt index now (add F2 blocks it).
        try writeCorruptIndex([
            (id: "sd-early", label: "Main", epoch: 1_000, sd: true),
            (id: "sd-late", label: "Other", epoch: 2_000, sd: true),
        ], to: url)
        let r2 = AccountRegistry(indexFileURL: url)   // load + normalize
        #expect(r2.accounts.filter(\.isSystemDefault).count == 1)
        let survivor = try #require(r2.accounts.first(where: { $0.isSystemDefault }))
        #expect(survivor.createdAt == Date(timeIntervalSince1970: 1_000))   // earliest kept
        #expect(r2.accounts.count == 2)             // the other is demoted, not deleted
    }

    // #56 gap 2 / decision 4: normalize migrates a legacy UUID system-default id
    // to the fixed systemDefaultID.
    @Test("normalize migrates a legacy UUID system-default id to systemDefaultID (#56)")
    @MainActor func normalizeMigratesLegacyID() throws {
        let url = tempIndexURL()
        // #57 round-2: a legacy-id system-default can only exist as PERSISTED data now —
        // add()'s reserved-id ownership gate blocks producing it via the API.
        try writeCorruptIndex([
            (id: "legacy-uuid-1234", label: "Main", epoch: 1_000, sd: true),
        ], to: url)
        let r2 = AccountRegistry(indexFileURL: url)
        #expect(r2.accounts.first(where: { $0.isSystemDefault })?.id == Account.systemDefaultID)
    }

    // #56: a clean 0/1-system-default index must not be spuriously rewritten by normalize.
    @Test("normalize leaves a clean single system-default index byte-unchanged (#56)")
    @MainActor func normalizeLeavesCleanIndexUnchanged() throws {
        let url = tempIndexURL()
        let r1 = AccountRegistry(indexFileURL: url)
        try r1.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))
        let before = try Data(contentsOf: url)
        _ = AccountRegistry(indexFileURL: url)      // reload → normalize should be a no-op
        #expect(try Data(contentsOf: url) == before)
    }

    // #56 verify B1 (ensemble #3/#10): coexistence must be order-INdependent — a
    // pre-existing system-default "Main" must not block adding an isolated "Main".
    @Test("reverse order: system-default first, then isolated same label coexist (#56 verify B1)")
    @MainActor func systemDefaultFirstThenIsolatedSameLabel() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))  // system-default FIRST
        try registry.add(Account(label: "Main"))                                                       // isolated same label
        #expect(registry.accounts.count == 2)
        #expect(registry.accounts.filter { !$0.isSystemDefault }.count == 1)
    }

    // #56 verify C2 (round-2 #1): a failed save must roll back the in-memory append —
    // no phantom account left in `accounts`.
    @Test("add rolls back the in-memory append when save fails (#56 verify C2)")
    @MainActor func addRollsBackOnSaveFailure() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        let url = blocker.appendingPathComponent("index.json")   // parent is a FILE → save throws
        let registry = AccountRegistry(indexFileURL: url)
        #expect(throws: (any Error).self) { try registry.add(Account(label: "Work")) }
        #expect(registry.accounts.isEmpty)                       // rolled back — no phantom
    }

    // #56 verify C3 (round-2 DA #10): coexistence must hold under rename too — B1 fixed
    // add()/createAccount() but missed rename.
    @Test("rename an isolated account to a system-default's label is allowed (#56 verify C3)")
    @MainActor func renameIsolatedToSystemDefaultLabel() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))
        let work = try registry.create(label: "Work")
        try registry.rename(accountId: work.id, to: "Main")      // isolated → system-default's label; must NOT throw
        #expect(registry.accounts.first(where: { $0.id == work.id })?.label == "Main")
        #expect(registry.accounts.filter { $0.label == "Main" }.count == 2)   // coexist
    }

    // #56 verify B2 (ensemble #1/#11/#12/#23): normalize must not synthesize two
    // accounts sharing id "system-default" when the demoted extra already holds it.
    @Test("normalize does not create duplicate ids when a demoted extra already holds the fixed id (#56 verify B2)")
    @MainActor func normalizeNoDuplicateIDOnCollision() throws {
        let url = tempIndexURL()
        // #57: corrupt index (two system-defaults) — add F2 blocks producing this via API.
        try writeCorruptIndex([
            (id: "legacy-uuid", label: "Main", epoch: 1_000, sd: true),           // canonical → migrates INTO fixed id
            (id: Account.systemDefaultID, label: "Old", epoch: 2_000, sd: true),  // later, already holds fixed id → demoted
        ], to: url)
        let r2 = AccountRegistry(indexFileURL: url)   // normalize
        let ids = r2.accounts.map(\.id)
        #expect(Set(ids).count == ids.count)          // no duplicate ids
        #expect(r2.accounts.filter { $0.id == Account.systemDefaultID }.count == 1)
        #expect(r2.accounts.filter { $0.isSystemDefault }.count == 1)

        // #57 F1: an ISOLATED account crafted with the reserved id must also not collide —
        // the canonical migration reassigns the occupant a fresh id first.
    }

    // #57 F1 (round-2 #2): normalize must not create a duplicate when an ISOLATED
    // account already holds the reserved id and a legacy system-default migrates into it.
    @Test("normalize reassigns an isolated account that squats the reserved id (#57 F1)")
    @MainActor func normalizeIsolatedHoldsFixedID() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: "legacy-uuid", label: "Main", epoch: 1_000, sd: true),           // system-default → migrates to fixed id
            (id: Account.systemDefaultID, label: "Squatter", epoch: 2_000, sd: false),  // isolated squatting the reserved id
        ], to: url)
        let r2 = AccountRegistry(indexFileURL: url)
        let ids = r2.accounts.map(\.id)
        #expect(Set(ids).count == ids.count)          // no duplicate ids
        // the system-default now holds the fixed id; the squatter got a fresh one
        #expect(r2.accounts.first(where: { $0.isSystemDefault })?.id == Account.systemDefaultID)
        #expect(r2.accounts.first(where: { $0.label == "Squatter" })?.id != Account.systemDefaultID)
    }

    // #57 F3 (round-2 #5): a demoted extra whose label collides with an existing
    // isolated label is suffixed, preserving isolated-label-uniqueness.
    @Test("normalize uniquifies a demoted label that collides with an isolated one (#57 F3)")
    @MainActor func normalizeDemoteLabelCollision() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: "iso", label: "Main", epoch: 500, sd: false),          // isolated "Main"
            (id: "sd-1", label: "Canonical", epoch: 1_000, sd: true),   // canonical system-default (kept)
            (id: "sd-2", label: "Main", epoch: 2_000, sd: true),        // extra system-default named "Main" → demoted
        ], to: url)
        let r2 = AccountRegistry(indexFileURL: url)
        let isolatedMains = r2.accounts.filter { !$0.isSystemDefault && $0.label.hasPrefix("Main") }
        #expect(isolatedMains.count == 2)                                       // both survive
        #expect(Set(isolatedMains.map(\.label)).count == 2)                     // but with DISTINCT labels
    }

    // #57 verify B (a): a steady-state canonical (already holding the fixed id) used to
    // skip the id-uniqueness sweep entirely — an isolated squatter of the reserved id
    // survived normalize and kept a duplicate id on disk.
    @Test("normalize evicts a reserved-id squatter when the canonical already holds the fixed id (#57 verify B)")
    @MainActor func normalizeEvictsSquatterInSteadyState() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: Account.systemDefaultID, label: "Main", epoch: 1_000, sd: true),          // clean canonical
            (id: Account.systemDefaultID, label: "Squatter", epoch: 2_000, sd: false),     // duplicate reserved id
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        let ids = r.accounts.map(\.id)
        #expect(Set(ids).count == ids.count)                                               // ids unique
        #expect(r.accounts.first(where: { $0.isSystemDefault })?.id == Account.systemDefaultID)
        #expect(r.accounts.first(where: { $0.label == "Squatter" })?.id != Account.systemDefaultID)
        // and the repair PERSISTS — a reload must not resurrect the duplicate
        let reloaded = AccountRegistry(indexFileURL: url)
        #expect(Set(reloaded.accounts.map(\.id)).count == reloaded.accounts.count)
    }

    // #57 verify B (b): zero system-defaults used to early-return — duplicate ids among
    // isolated accounts were never repaired.
    @Test("normalize repairs duplicate ids when no system-default exists (#57 verify B)")
    @MainActor func normalizeRepairsDuplicateIDsWithoutSystemDefault() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: "dup", label: "A", epoch: 1_000, sd: false),
            (id: "dup", label: "B", epoch: 2_000, sd: false),
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.count == 2)                                       // both survive
        #expect(Set(r.accounts.map(\.id)).count == 2)                        // ids unique
        #expect(r.accounts.first(where: { $0.label == "A" })?.id == "dup")   // first occurrence keeps its id
    }

    // #57 verify B (b): an isolated squatter of the reserved id blocks
    // addSystemDefaultAccount forever (add's F1 gate throws duplicateID) — normalize
    // must free the reserved id even when NO system-default exists yet.
    @Test("normalize frees the reserved id when no system-default exists (#57 verify B)")
    @MainActor func normalizeFreesReservedIDWithoutSystemDefault() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: Account.systemDefaultID, label: "Squatter", epoch: 1_000, sd: false),
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.first(where: { $0.label == "Squatter" })?.id != Account.systemDefaultID)
        // the reserved id is usable again — the "Main" add path is unblocked:
        try r.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))
        #expect(r.accounts.filter(\.isSystemDefault).count == 1)
    }

    // #57 verify B (c): with MULTIPLE occupants of the reserved id, only the FIRST was
    // re-idded — the canonical migration still landed on a duplicate.
    @Test("normalize re-ids ALL reserved-id occupants during canonical migration (#57 verify B)")
    @MainActor func normalizeReIDsAllOccupants() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: "legacy-uuid", label: "Main", epoch: 1_000, sd: true),                 // canonical → migrates INTO fixed id
            (id: Account.systemDefaultID, label: "Sq1", epoch: 2_000, sd: false),
            (id: Account.systemDefaultID, label: "Sq2", epoch: 3_000, sd: false),
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.count == 3)
        let ids = r.accounts.map(\.id)
        #expect(Set(ids).count == ids.count)                                            // all unique
        #expect(r.accounts.filter { $0.id == Account.systemDefaultID }.count == 1)
        #expect(r.accounts.first(where: { $0.id == Account.systemDefaultID })?.isSystemDefault == true)
    }

    // #57 F1 (round-2 #2): add rejects a duplicate id (global id-uniqueness).
    @Test("add rejects a duplicate id (#57 F1)")
    @MainActor func addRejectsDuplicateID() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.add(Account(id: "dup", label: "A"))
        #expect(throws: Account.ValidationError.duplicateID) {
            try registry.add(Account(id: "dup", label: "B"))
        }
    }

    // #57 F2 (round-2 #3): add rejects a second system-default.
    @Test("add rejects a second system-default (#57 F2)")
    @MainActor func addRejectsSecondSystemDefault() throws {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        try registry.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))
        #expect(throws: Account.ValidationError.duplicateSystemDefault) {
            try registry.add(Account(id: "other-sd", label: "Other", isSystemDefault: true))
        }
    }

    // #57 verify A: remove must PROPAGATE a persist failure (not swallow it) so callers
    // (AccountManager) can keep their own state in sync with the rolled-back list.
    @Test("remove throws and rolls back on save failure (#57 verify A)")
    @MainActor func removeThrowsAndRollsBackOnSaveFailure() throws {
        let url = tempIndexURL()
        let registry = AccountRegistry(indexFileURL: url)
        let acc = try registry.create(label: "work")           // saves OK
        let parent = url.deletingLastPathComponent()
        // read-only parent → the atomic write's temp file can't be created → save throws
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        #expect(throws: (any Error).self) { try registry.remove(accountId: acc.id) }
        #expect(registry.accounts.map(\.id) == [acc.id])       // rolled back — still present
    }

    // #57 round-2 verify #1: the reserved id belongs to the system-default alone —
    // add() must enforce OWNERSHIP at mutation time (not only normalize() at next load).
    @Test("add rejects an isolated account holding the reserved id (#57 round-2)")
    @MainActor func addRejectsIsolatedReservedID() {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        #expect(throws: Account.ValidationError.reservedID) {
            try registry.add(Account(id: Account.systemDefaultID, label: "Squatter"))
        }
        #expect(registry.accounts.isEmpty)
    }

    // #57 round-2 verify #1 (other direction): a system-default must hold the fixed id.
    @Test("add rejects a system-default whose id is not the fixed id (#57 round-2)")
    @MainActor func addRejectsSystemDefaultWithWrongID() {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        #expect(throws: Account.ValidationError.reservedID) {
            try registry.add(Account(id: "legacy-uuid", label: "Main", isSystemDefault: true))
        }
        #expect(registry.accounts.isEmpty)
    }

    // #57 round-2 verify #5: removing a nonexistent id is a no-op — it must not touch
    // the disk at all, so it cannot spuriously throw on a broken disk (parity with
    // rename's nonexistent-id guard).
    @Test("remove of a nonexistent id is a no-op even when the disk is unwritable (#57 round-2)")
    @MainActor func removeGhostNoOpOnBrokenDisk() throws {
        let url = tempIndexURL()
        let registry = AccountRegistry(indexFileURL: url)
        let acc = try registry.create(label: "work")
        let parent = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        try registry.remove(accountId: "ghost")            // must NOT throw
        #expect(registry.accounts.map(\.id) == [acc.id])   // unchanged
    }

    // #57 round-2 (requirements F3 note): two demoted extras sharing a label must be
    // uniquified against EACH OTHER, not only against pre-existing isolated labels.
    @Test("normalize uniquifies two demoted extras sharing the same label (#57 F3)")
    @MainActor func normalizeDemoteLabelCollisionBetweenExtras() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: "sd-1", label: "Canonical", epoch: 1_000, sd: true),
            (id: "sd-2", label: "Main", epoch: 2_000, sd: true),
            (id: "sd-3", label: "Main", epoch: 3_000, sd: true),
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        let demoted = r.accounts.filter { !$0.isSystemDefault }
        #expect(demoted.count == 2)
        #expect(Set(demoted.map(\.label)).count == 2)   // distinct labels
    }

    // #58: normalize must RECORD the old id of every account phase 2 re-ids — that
    // id's ownership is ambiguous after the repair (it may still resolve, to a
    // DIFFERENT account), and AccountManager consumes the set to heal a
    // resolvable-but-wrong stored active id.
    @Test("normalize records the evicted squatter's old id in reassignedIDs (#58)")
    @MainActor func reassignedIDsRecordsSquatterEviction() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: Account.systemDefaultID, label: "Main", epoch: 1_000, sd: true),
            (id: Account.systemDefaultID, label: "Squatter", epoch: 2_000, sd: false),
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.reassignedIDs == [Account.systemDefaultID])
    }

    // #58: a clean index must not flag anything — no spurious heals downstream.
    @Test("a clean index leaves reassignedIDs empty (#58)")
    @MainActor func reassignedIDsEmptyOnCleanIndex() throws {
        let url = tempIndexURL()
        let r1 = AccountRegistry(indexFileURL: url)
        try r1.add(Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true))
        try r1.create(label: "Work")
        let r2 = AccountRegistry(indexFileURL: url)   // reload → normalize is a no-op
        #expect(r2.reassignedIDs.isEmpty)
    }

    // #58: general duplicates count too — the first occupant keeps the id, so the
    // id still resolves; any stored selection on it is ambiguous and must be flagged.
    @Test("normalize records a duplicated id when its later occupant is re-idded (#58)")
    @MainActor func reassignedIDsRecordsDuplicateEviction() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: "dup", label: "A", epoch: 1_000, sd: false),
            (id: "dup", label: "B", epoch: 2_000, sd: false),
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.reassignedIDs == ["dup"])
    }

    // #59: labels from DISK bypass Account.validate (init(from:) doesn't trim) —
    // normalize's phase-3 label pass must repair them to the same invariants the
    // mutation paths enforce. Labels are cosmetic (config dirs key off id), so
    // load-time repair is safe.
    @Test("normalize trims an untrimmed persisted label (#59)")
    @MainActor func normalizeTrimsPersistedLabel() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([(id: "a", label: "  Work  ", epoch: 1_000, sd: false)], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.first?.label == "Work")
        // repair persists — reload sees the trimmed label
        #expect(AccountRegistry(indexFileURL: url).accounts.first?.label == "Work")
    }

    @Test("normalize replaces an empty persisted label with a placeholder (#59)")
    @MainActor func normalizeReplacesEmptyLabel() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([(id: "a", label: "   ", epoch: 1_000, sd: false)], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.first?.label == "(unnamed)")
    }

    @Test("normalize clamps an over-30-char persisted label (#59)")
    @MainActor func normalizeClampsLongLabel() throws {
        let url = tempIndexURL()
        let long = String(repeating: "x", count: 45)
        try writeCorruptIndex([(id: "a", label: long, epoch: 1_000, sd: false)], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.first?.label == String(repeating: "x", count: 30))
    }

    @Test("normalize uniquifies persisted duplicate isolated labels (#59)")
    @MainActor func normalizeUniquifiesPersistedDuplicateLabels() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: "a", label: "Work", epoch: 1_000, sd: false),
            (id: "b", label: "Work", epoch: 2_000, sd: false),
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.first(where: { $0.id == "a" })?.label == "Work")               // first keeps
        #expect(r.accounts.first(where: { $0.id == "b" })?.label == "Work (recovered)")   // F3 convention
    }

    // #59: trimming itself can CREATE a duplicate — uniquify must run after cleanup.
    @Test("normalize uniquifies labels that collide only after trimming (#59)")
    @MainActor func normalizeUniquifiesPostTrimCollision() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: "a", label: "Work", epoch: 1_000, sd: false),
            (id: "b", label: "  Work", epoch: 2_000, sd: false),
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        let labels = Set(r.accounts.map(\.label))
        #expect(labels == ["Work", "Work (recovered)"])
    }

    // #59: the system-default's label gets CLEANUP but not uniqueness — a
    // system-default "Main" still coexists with an isolated "Main" (#56 B1).
    @Test("system-default label is cleaned but exempt from uniquification (#59)")
    @MainActor func systemDefaultLabelCleanedNotUniquified() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: Account.systemDefaultID, label: "  Main ", epoch: 1_000, sd: true),
            (id: "iso", label: "Main", epoch: 2_000, sd: false),
        ], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.first(where: { $0.isSystemDefault })?.label == "Main")   // trimmed
        #expect(r.accounts.first(where: { $0.id == "iso" })?.label == "Main")       // NOT suffixed — coexists
    }

    // #59: idempotence — a repaired index must be stable on the next load.
    @Test("label repair is idempotent — repaired index reloads byte-unchanged (#59)")
    @MainActor func labelRepairIdempotent() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([
            (id: "a", label: "  Work  ", epoch: 1_000, sd: false),
            (id: "b", label: "Work", epoch: 2_000, sd: false),
        ], to: url)
        _ = AccountRegistry(indexFileURL: url)          // first load repairs + persists
        let after = try Data(contentsOf: url)
        _ = AccountRegistry(indexFileURL: url)          // second load must be a no-op
        #expect(try Data(contentsOf: url) == after)
    }

    // #59 verify (blocking): at an exact-cap collision (two identical 30-char labels)
    // the cleanup clamp and the uniquify suffix undo each other — a per-step changed
    // flag fires save() on EVERY load forever even though the bytes are stable. The
    // pass must converge: after the first repairing save, later loads must not write.
    // (Read-only parent makes a write ATTEMPT observable: any attempted save would
    // fail and flip normalizeDidPersist to false.)
    @Test("label repair converges — no rewrite on subsequent loads at exact-cap collision (#59 verify)")
    @MainActor func labelRepairConvergesAtExactCapCollision() throws {
        let url = tempIndexURL()
        let cap = String(repeating: "x", count: 30)
        try writeCorruptIndex([
            (id: "a", label: cap, epoch: 1_000, sd: false),
            (id: "b", label: cap, epoch: 2_000, sd: false),
        ], to: url)
        _ = AccountRegistry(indexFileURL: url)               // load 1: repairs + saves
        let parent = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let r2 = AccountRegistry(indexFileURL: url)          // load 2: MUST be a no-op
        #expect(r2.normalizeDidPersist == true)              // no write attempted — converged
        #expect(r2.accounts.first(where: { $0.id == "a" })?.label == cap)
        #expect(r2.accounts.first(where: { $0.id == "b" })?.label == "\(cap) (recovered)")
    }

    // #59 verify: `.whitespaces` misses newline-only labels — a "\n" label dodged the
    // empty-placeholder repair. Phase 3 trims newlines too (decode can carry them).
    @Test("normalize replaces a newline-only persisted label with the placeholder (#59 verify)")
    @MainActor func normalizeReplacesNewlineOnlyLabel() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([(id: "a", label: "\\n", epoch: 1_000, sd: false)], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.first?.label == "(unnamed)")
    }

    // #59 verify (pin): a clamp that lands on trailing whitespace re-trims via
    // Account.init to a 29-char stable result — converges, no tug-of-war.
    @Test("clamp landing on trailing whitespace converges to the trimmed result (#59 verify)")
    @MainActor func clampOnTrailingWhitespaceConverges() throws {
        let url = tempIndexURL()
        let label = String(repeating: "x", count: 29) + " y"    // 31 chars; prefix(30) ends in space
        try writeCorruptIndex([(id: "a", label: label, epoch: 1_000, sd: false)], to: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.first?.label == String(repeating: "x", count: 29))
        #expect(AccountRegistry(indexFileURL: url).accounts.first?.label == String(repeating: "x", count: 29))
    }

    // #61: the id is a config-dir path component — malformed ids are rejected at the
    // mutation gate, not just repaired at next load.
    @Test("add rejects a malformed id (#61)")
    @MainActor func addRejectsMalformedID() {
        let registry = AccountRegistry(indexFileURL: tempIndexURL())
        #expect(throws: Account.ValidationError.invalidID) {
            try registry.add(Account(id: "../../evil", label: "X"))
        }
        #expect(throws: Account.ValidationError.invalidID) {
            try registry.add(Account(id: "", label: "Y"))
        }
        #expect(registry.accounts.isEmpty)
    }

    // #61: a persisted malformed id is re-idded at load. The OLD id must NOT enter
    // reassignedIDs — nothing can hold it afterwards (dangling), so the existing
    // active==nil heal covers a stored selection pointing at it.
    @Test("normalize re-ids a malformed persisted id, not flagged reassigned (#61)")
    @MainActor func normalizeReIDsMalformedID() throws {
        let url = tempIndexURL()
        try writeCorruptIndex([(id: "../../evil", label: "X", epoch: 1_000, sd: false)], to: url)
        let r = AccountRegistry(indexFileURL: url)
        let id = try #require(r.accounts.first?.id)
        #expect(Account.isValidID(id))
        #expect(id != "../../evil")
        #expect(!r.reassignedIDs.contains("../../evil"))
        #expect(AccountRegistry(indexFileURL: url).accounts.first?.id == id)   // repair persisted
    }

    // #61: caps on the attacker-writable index — beyond either cap the file is
    // treated exactly like a corrupt one (load empty, preserve the bytes as evidence).
    @Test("an index over the byte cap loads empty and is preserved (#61)")
    @MainActor func loadRejectsOversizedIndex() throws {
        let url = tempIndexURL()
        let bigLabel = String(repeating: "a", count: 1_100_000)
        try writeCorruptIndex([(id: "a", label: bigLabel, epoch: 1_000, sd: false)], to: url)
        let before = try Data(contentsOf: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.isEmpty)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("an index over the account-count cap loads empty and is preserved (#61)")
    @MainActor func loadRejectsTooManyAccounts() throws {
        let url = tempIndexURL()
        try writeCorruptIndex((1...501).map { (id: "a\($0)", label: "L\($0)", epoch: TimeInterval($0), sd: false) }, to: url)
        let before = try Data(contentsOf: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.isEmpty)
        #expect(try Data(contentsOf: url) == before)
    }

    // #61: defense-in-depth permissions — the index may carry user-chosen labels, and
    // the accounts root holds per-account config dirs.
    @Test("save applies restrictive permissions — 0o700 dir, 0o600 index (#61)")
    @MainActor func savePermissions() throws {
        let url = tempIndexURL()               // parent does not exist — save creates it
        let registry = AccountRegistry(indexFileURL: url)
        try registry.create(label: "work")
        let fm = FileManager.default
        let dirPerms = try #require(try fm.attributesOfItem(
            atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)
        let filePerms = try #require(try fm.attributesOfItem(
            atPath: url.path)[.posixPermissions] as? NSNumber)
        #expect(dirPerms.uint16Value == 0o700)
        #expect(filePerms.uint16Value == 0o600)
    }

    // #61 verify (blocking): the accounts root must converge to 0o700 even when it
    // ALREADY EXISTS at a looser mode — the create-time `attributes:` param is a
    // no-op on a pre-existing dir, and in the real createAccount flow
    // AccountManager.ensureDirectory creates the chain (umask default) BEFORE save()
    // runs. A 0o700 root blocks other-user traversal into every `<id>/.claude`
    // beneath it, so the root converging is the load-bearing hardening.
    @Test("save hardens a pre-existing accounts root to 0o700 (#61 verify)")
    @MainActor func saveHardensPreExistingRoot() throws {
        let url = tempIndexURL()
        let root = url.deletingLastPathComponent()
        // Simulate ensureDirectory building the chain first at a looser umask mode.
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let registry = AccountRegistry(indexFileURL: url)
        try registry.create(label: "work")                 // triggers save() against the pre-existing root
        let perms = try #require(try FileManager.default.attributesOfItem(
            atPath: root.path)[.posixPermissions] as? NSNumber)
        #expect(perms.uint16Value == 0o700)                // converged despite pre-existing 0o755
    }

    // #61 verify (LOW): an oversized index is rejected WITHOUT reading the whole file
    // into memory first — stat before read. (Same load-empty + preserve semantics.)
    @Test("oversized index is rejected by stat before a full read (#61 verify)")
    @MainActor func loadStatsBeforeReadingOversized() throws {
        let url = tempIndexURL()
        let bigLabel = String(repeating: "b", count: 1_200_000)
        try writeCorruptIndex([(id: "a", label: bigLabel, epoch: 1_000, sd: false)], to: url)
        let before = try Data(contentsOf: url)
        let r = AccountRegistry(indexFileURL: url)
        #expect(r.accounts.isEmpty)
        #expect(try Data(contentsOf: url) == before)       // preserved
    }

    // #57 (round-2 transactional primitive): rename rolls back on save failure, like add.
    @Test("rename rolls back on save failure (#57 mutate)")
    @MainActor func renameRollsBackOnSaveFailure() throws {
        let url = tempIndexURL()
        let registry = AccountRegistry(indexFileURL: url)
        let acc = try registry.create(label: "work")           // saves OK
        let parent = url.deletingLastPathComponent()
        // read-only parent → the atomic write's temp file can't be created → save throws
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        #expect(throws: (any Error).self) { try registry.rename(accountId: acc.id, to: "work2") }
        #expect(registry.accounts.first?.label == "work")      // rolled back — label unchanged
    }
}
