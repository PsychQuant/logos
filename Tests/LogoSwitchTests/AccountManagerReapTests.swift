import Testing
import Foundation
@testable import LogoSwitch
import LogosAccounts

/// #50: `AccountManager.remove` reaps the removed account's isolated data dir
/// (composing with the #57 rollback), and `reapOrphanedDirectories` runs the
/// conservative one-shot startup GC. Each test injects a temp-home reaper + temp
/// index so the real `~/.logos/accounts` tree is never touched.
@Suite("AccountManager reap (#50)", .serialized)
@MainActor
struct AccountManagerReapTests {

    private let fm = FileManager.default

    private func tempHome() throws -> URL {
        let home = fm.temporaryDirectory.appendingPathComponent("acct-mgr-reap-\(UUID().uuidString)")
        try fm.createDirectory(at: AccountsRoot.url(home: home), withIntermediateDirectories: true)
        return home
    }

    private func tempIndexURL() -> URL {
        fm.temporaryDirectory
            .appendingPathComponent("acct-mgr-reap-index-\(UUID().uuidString)")
            .appendingPathComponent("index.json")
    }

    /// Materialize a real `<home>/.logos/accounts/<id>/.claude` dir with a marker
    /// file, mirroring what `ensureDirectory` + a live session leave behind.
    @discardableResult
    private func makeDir(home: URL, id: String) throws -> URL {
        let dir = AccountsRoot.url(home: home).appendingPathComponent(id)
        try fm.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: dir.appendingPathComponent("marker"))
        return dir
    }

    private func makeManager(home: URL, indexURL: URL) -> AccountManager {
        AccountManager(
            registry: AccountRegistry(indexFileURL: indexURL),
            store: InMemoryActiveAccountStore(),
            ensureDirectory: { _ in },              // no real FS from create; we plant dirs by hand
            reaper: AccountReaper(home: home))
    }

    // The dominant bug (#50 vector B): remove now deletes the account's dir.
    @Test("remove deletes the removed account's isolated data dir")
    func removeDeletesDir() throws {
        let home = try tempHome(); defer { try? fm.removeItem(at: home) }
        let indexURL = tempIndexURL()
        let mgr = makeManager(home: home, indexURL: indexURL)
        let acc = try mgr.createAccount(label: "work")
        let dir = try makeDir(home: home, id: acc.id)
        #expect(fm.fileExists(atPath: dir.path))
        #expect(mgr.remove(accountId: acc.id) == true)
        #expect(!fm.fileExists(atPath: dir.path))   // reaped after the registry persist
    }

    // #57 rollback composition: a persist-failed (rolled-back) remove must NOT delete.
    @Test("a rolled-back remove (persist fails) KEEPS the account dir")
    func rolledBackRemoveKeepsDir() throws {
        let home = try tempHome(); defer { try? fm.removeItem(at: home) }
        let indexURL = tempIndexURL()
        let mgr = makeManager(home: home, indexURL: indexURL)
        try mgr.createAccount(label: "a")
        let b = try mgr.createAccount(label: "b")
        let dir = try makeDir(home: home, id: b.id)
        // read-only index parent → registry.save throws → remove rolls back → returns false
        let parent = indexURL.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        #expect(mgr.remove(accountId: b.id) == false)   // rolled back
        #expect(mgr.accounts.count == 2)                // account still alive
        #expect(fm.fileExists(atPath: dir.path))        // dir NOT reaped
    }

    // The system-default reuses the shared ~/.claude — its dir must never be reaped.
    @Test("removing a system-default account does NOT reap its dir")
    func systemDefaultDirSpared() throws {
        let home = try tempHome(); defer { try? fm.removeItem(at: home) }
        let indexURL = tempIndexURL()
        let mgr = makeManager(home: home, indexURL: indexURL)
        _ = mgr.addSystemDefaultAccount()
        let main = try #require(mgr.accounts.first { $0.isSystemDefault })
        // A dir under the accounts root for the system-default id (defensive: never
        // legitimately created, but prove the guard would spare it if present).
        let dir = try makeDir(home: home, id: main.id)
        #expect(mgr.remove(accountId: main.id) == true)   // unregistered from the index
        #expect(fm.fileExists(atPath: dir.path))          // but its dir is SPARED (guard)
    }

    // reapOrphanedDirectories wiring: an unregistered no-config dir is reaped;
    // a registered account's dir is spared.
    @Test("reapOrphanedDirectories reaps orphans and spares registered accounts")
    func startupGCReapsOnlyOrphans() throws {
        let home = try tempHome(); defer { try? fm.removeItem(at: home) }
        let indexURL = tempIndexURL()
        let mgr = makeManager(home: home, indexURL: indexURL)
        let live = try mgr.createAccount(label: "live")
        let liveDir = try makeDir(home: home, id: live.id)          // registered → spared
        let orphanDir = try makeDir(home: home, id: "orphan-x")     // unregistered, no config → reaped
        mgr.reapOrphanedDirectories()
        #expect(fm.fileExists(atPath: liveDir.path))
        #expect(!fm.fileExists(atPath: orphanDir.path))
    }
}
