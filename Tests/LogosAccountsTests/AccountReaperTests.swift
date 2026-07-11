import Testing
import Foundation
@testable import LogosAccounts

/// #50: the conservative one-shot startup GC + its guarded delete core. Every
/// test operates on a per-test temp home so the real `~/.logos/accounts` tree is
/// never touched.
@Suite("AccountReaper", .serialized)
struct AccountReaperTests {

    private let fm = FileManager.default

    /// A fresh temp home with an empty `~/.logos/accounts` root. Caller cleans up.
    private func tempHome() throws -> URL {
        let home = fm.temporaryDirectory.appendingPathComponent("account-reaper-\(UUID().uuidString)")
        try fm.createDirectory(at: AccountsRoot.url(home: home), withIntermediateDirectories: true)
        return home
    }

    /// Create `<root>/<id>/` (optionally with a claude config JSON inside its
    /// `.claude`), plus a marker file so a spared dir is provably intact.
    @discardableResult
    private func makeAccountDir(home: URL, id: String, withConfigJSON: Bool) throws -> URL {
        let dir = AccountsRoot.url(home: home).appendingPathComponent(id)
        let claude = dir.appendingPathComponent(".claude")
        try fm.createDirectory(at: claude, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: dir.appendingPathComponent("marker"))
        if withConfigJSON {
            try Data("{}".utf8).write(to: claude.appendingPathComponent(".claude.json"))
        }
        return dir
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    @Test("reaps a true orphan — absent from the registry and no config JSON")
    func reapsTrueOrphan() throws {
        let home = try tempHome()
        defer { try? fm.removeItem(at: home) }
        let orphan = try makeAccountDir(home: home, id: "orphan-1", withConfigJSON: false)
        let reaped = AccountReaper(home: home).reapOrphans(liveIDs: [])
        #expect(reaped == ["orphan-1"])
        #expect(!exists(orphan))
    }

    @Test("spares a registered account even with no config JSON (shell dir)")
    func sparesRegisteredEntry() throws {
        let home = try tempHome()
        defer { try? fm.removeItem(at: home) }
        let live = try makeAccountDir(home: home, id: "live-1", withConfigJSON: false)
        let reaped = AccountReaper(home: home).reapOrphans(liveIDs: ["live-1"])
        #expect(reaped.isEmpty)
        #expect(exists(live))   // registered → spared
    }

    @Test("spares a dir that carries a claude config JSON even if unregistered")
    func sparesConfigJSONDir() throws {
        let home = try tempHome()
        defer { try? fm.removeItem(at: home) }
        let real = try makeAccountDir(home: home, id: "real-1", withConfigJSON: true)
        let reaped = AccountReaper(home: home).reapOrphans(liveIDs: [])
        #expect(reaped.isEmpty)
        #expect(exists(real))   // has a config JSON → a real account → spared
    }

    @Test("spares the registered system-default id")
    func sparesSystemDefault() throws {
        let home = try tempHome()
        defer { try? fm.removeItem(at: home) }
        // A dir under the accounts root named for the system-default, registered.
        let sd = try makeAccountDir(home: home, id: Account.systemDefaultID, withConfigJSON: false)
        let reaped = AccountReaper(home: home).reapOrphans(liveIDs: [Account.systemDefaultID])
        #expect(reaped.isEmpty)
        #expect(exists(sd))
    }

    @Test("never follows a symlink out of the accounts root")
    func refusesSymlink() throws {
        let home = try tempHome()
        defer { try? fm.removeItem(at: home) }
        // A real victim OUTSIDE the accounts root, and a symlink to it planted inside.
        let victim = home.appendingPathComponent("victim-dir")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("keep"))
        let link = AccountsRoot.url(home: home).appendingPathComponent("evil-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: victim)
        let reaped = AccountReaper(home: home).reapOrphans(liveIDs: [])
        #expect(reaped.isEmpty)          // the symlink is refused, not reaped
        #expect(exists(victim))          // the link's target is untouched
        #expect(exists(victim.appendingPathComponent("keep")))
    }

    @Test("does not reap the index.json file sitting in the accounts root")
    func sparesIndexFile() throws {
        let home = try tempHome()
        defer { try? fm.removeItem(at: home) }
        let index = AccountsRoot.url(home: home).appendingPathComponent("index.json")
        try Data("{}".utf8).write(to: index)
        let reaped = AccountReaper(home: home).reapOrphans(liveIDs: [])
        #expect(reaped.isEmpty)     // a plain file is never a reap target
        #expect(exists(index))
    }

    @Test("reap(accountID:) removes an isolated account dir directly")
    func reapByIDDeletes() throws {
        let home = try tempHome()
        defer { try? fm.removeItem(at: home) }
        let dir = try makeAccountDir(home: home, id: "gone-1", withConfigJSON: true)
        #expect(AccountReaper(home: home).reap(accountID: "gone-1"))
        #expect(!exists(dir))
    }

    @Test("reap(accountID:) is a no-op for an absent dir")
    func reapByIDAbsentNoOp() throws {
        let home = try tempHome()
        defer { try? fm.removeItem(at: home) }
        #expect(AccountReaper(home: home).reap(accountID: "never-existed") == false)
    }

    @Test("startup GC is idempotent — a second run finds nothing")
    func gcIdempotent() throws {
        let home = try tempHome()
        defer { try? fm.removeItem(at: home) }
        try makeAccountDir(home: home, id: "orphan-a", withConfigJSON: false)
        try makeAccountDir(home: home, id: "orphan-b", withConfigJSON: false)
        let reaper = AccountReaper(home: home)
        #expect(Set(reaper.reapOrphans(liveIDs: [])) == ["orphan-a", "orphan-b"])
        #expect(reaper.reapOrphans(liveIDs: []).isEmpty)   // nothing left
    }
}
