import Testing
import Foundation
@testable import Logos

/// Acceptance suite for the `account-credential-isolation` change
/// (PsychQuant/logos#12). Pins the per-account `CLAUDE_CONFIG_DIR` /
/// `CLAUDE_SECURESTORAGE_CONFIG_DIR` emission and the no-write account switch.
@Suite("AccountCredentialIsolation", .serialized)
@MainActor
struct AccountCredentialIsolationTests {

    // MARK: - 2.1 Per-account isolated config directory

    @Test("distinct accounts yield distinct, non-empty configDirPath")
    func distinctConfigDirs() {
        let a = Account(id: "acc-a", label: "work")
        let b = Account(id: "acc-b", label: "personal")
        #expect(!a.configDirPath.isEmpty)
        #expect(!b.configDirPath.isEmpty)
        #expect(a.configDirPath != b.configDirPath)
    }

    @Test("configDirPath is the account's home + /.claude")
    func configDirDerivedFromHome() {
        let account = Account(id: "acc-x", label: "x")
        #expect(account.configDirPath == "\(account.homeDirectoryPath)/.claude")
        #expect(account.configDirPath.hasSuffix("/.logos/accounts/acc-x/.claude"))
    }

    // MARK: - 2.2 ClaudeProcessConfig env emission

    @Test("account spawn emits CLAUDE_CONFIG_DIR == configDirPath")
    func emitsConfigDir() {
        let account = Account(id: "acc-1", label: "work")
        let cfg = ClaudeProcessConfig(
            executablePath: "/usr/local/bin/claude",
            account: account
        )
        #expect(cfg.environment["CLAUDE_CONFIG_DIR"] == account.configDirPath)
        #expect(cfg.environment["CLAUDE_CONFIG_DIR"]?.isEmpty == false)
    }

    @Test("account spawn emits CLAUDE_SECURESTORAGE_CONFIG_DIR == configDirPath (the service-name key)")
    func emitsSecureStorageConfigDir() {
        let account = Account(id: "acc-2", label: "work")
        let cfg = ClaudeProcessConfig(
            executablePath: "/usr/local/bin/claude",
            account: account
        )
        #expect(cfg.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == account.configDirPath)
        #expect(cfg.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]?.isEmpty == false)
    }

    @Test("inherited empty CLAUDE_SECURESTORAGE_CONFIG_DIR is overwritten for an account spawn")
    func overwritesInheritedEmptyForAccount() {
        let account = Account(id: "acc-3", label: "work")
        let cfg = ClaudeProcessConfig(
            executablePath: "/usr/local/bin/claude",
            account: account,
            baseEnvironment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": ""]
        )
        // The empty value would force the bare service name; it must be replaced
        // with the per-account dir, never left empty.
        #expect(cfg.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == account.configDirPath)
        #expect(cfg.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]?.isEmpty == false)
    }

    @Test("inherited empty CLAUDE_SECURESTORAGE_CONFIG_DIR is stripped when no account")
    func stripsInheritedEmptyNoAccount() {
        let cfg = ClaudeProcessConfig(
            executablePath: "/usr/local/bin/claude",
            baseEnvironment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": ""]
        )
        // No account → no per-account dir to set, but an empty value is a trap,
        // so it must be removed rather than passed through.
        #expect(cfg.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
    }

    @Test("no account → no CLAUDE_CONFIG_DIR injected")
    func noAccountNoConfigDir() {
        let cfg = ClaudeProcessConfig(
            executablePath: "/usr/local/bin/claude",
            baseEnvironment: [:]
        )
        #expect(cfg.environment["CLAUDE_CONFIG_DIR"] == nil)
    }

    // MARK: - 3.1 Account switching performs no system Keychain write

    @Test("setActive performs zero system-Keychain interaction and still switches")
    func setActiveZeroInteraction() throws {
        let spy = CountingSystemKeychainBridge()
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: spy,
            defaults: makeDefaults()
        )
        try mgr.add(label: "work", credentials: Data("{}".utf8))
        try mgr.add(label: "personal", credentials: Data("{}".utf8))
        let personalId = mgr.accounts[1].id

        mgr.setActive(personalId)

        #expect(mgr.active?.id == personalId)
        // The shared system entry is never touched — not even read — by a switch.
        #expect(spy.readCount == 0)
        #expect(spy.existsCount == 0)
    }

    @Test("remove performs zero system-Keychain interaction")
    func removeZeroInteraction() throws {
        let spy = CountingSystemKeychainBridge()
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: spy,
            defaults: makeDefaults()
        )
        try mgr.add(label: "a", credentials: Data("{}".utf8))
        try mgr.add(label: "b", credentials: Data("{}".utf8))
        let aId = mgr.accounts[0].id

        try mgr.remove(accountId: aId)

        #expect(mgr.accounts.count == 1)
        #expect(spy.readCount == 0)
        #expect(spy.existsCount == 0)
    }

    // MARK: - 4.1 needs-reauth (promptless detection)

    @Test("needs-reauth is true with no flag and no credentials file (no Keychain read)")
    func needsReauthByDefault() throws {
        let fs = FSDouble()
        let spy = CountingSystemKeychainBridge()
        let mgr = makeManager(fs: fs, bridge: spy)
        try mgr.add(label: "work", credentials: Data("{}".utf8))
        let acc = mgr.accounts[0]

        #expect(mgr.needsReauth(acc) == true)
        #expect(spy.readCount == 0)
        #expect(spy.existsCount == 0)
    }

    @Test("authenticated flag clears needs-reauth")
    func flagClearsNeedsReauth() throws {
        let fs = FSDouble()
        let spy = CountingSystemKeychainBridge()
        let mgr = makeManager(fs: fs, bridge: spy)
        try mgr.add(label: "work", credentials: Data("{}".utf8))
        let acc = mgr.accounts[0]

        mgr.markAuthenticated(acc.id)

        #expect(mgr.needsReauth(acc) == false)
        #expect(spy.readCount == 0)
        #expect(spy.existsCount == 0)
    }

    @Test("a .credentials.json file clears needs-reauth")
    func credentialsFileClearsNeedsReauth() throws {
        let fs = FSDouble()
        let spy = CountingSystemKeychainBridge()
        let mgr = makeManager(fs: fs, bridge: spy)
        try mgr.add(label: "work", credentials: Data("{}".utf8))
        let acc = mgr.accounts[0]
        fs.present.insert("\(acc.configDirPath)/.credentials.json")

        #expect(mgr.needsReauth(acc) == false)
        #expect(spy.readCount == 0)
        #expect(spy.existsCount == 0)
    }

    // MARK: - 4.2 non-destructive migration

    @Test("migration marks accounts needs-reauth, ensures config dirs, zero Keychain interaction")
    func migrationMarksNeedsReauth() throws {
        let fs = FSDouble()
        let spy = CountingSystemKeychainBridge()
        let mgr = makeManager(fs: fs, bridge: spy)
        try mgr.add(label: "a", credentials: Data("{}".utf8))
        try mgr.add(label: "b", credentials: Data("{}".utf8))
        // Pre-mark both authenticated; migration must clear them (no cred file).
        mgr.markAuthenticated(mgr.accounts[0].id)
        mgr.markAuthenticated(mgr.accounts[1].id)

        mgr.migrateToIsolatedCredentialsIfNeeded()

        #expect(mgr.needsReauth(mgr.accounts[0]) == true)
        #expect(mgr.needsReauth(mgr.accounts[1]) == true)
        #expect(Set(fs.created) == Set(mgr.accounts.map { $0.configDirPath }))
        #expect(spy.readCount == 0)
        #expect(spy.existsCount == 0)
    }

    @Test("migration keeps an account authenticated when its credentials file exists")
    func migrationKeepsCredFileAccount() throws {
        let fs = FSDouble()
        let mgr = makeManager(fs: fs, bridge: CountingSystemKeychainBridge())
        try mgr.add(label: "a", credentials: Data("{}".utf8))
        let acc = mgr.accounts[0]
        fs.present.insert("\(acc.configDirPath)/.credentials.json")

        mgr.migrateToIsolatedCredentialsIfNeeded()

        #expect(mgr.needsReauth(acc) == false)
    }

    @Test("migration is idempotent and does not re-clear a post-migration login")
    func migrationIdempotent() throws {
        let fs = FSDouble()
        let mgr = makeManager(fs: fs, bridge: CountingSystemKeychainBridge())
        try mgr.add(label: "a", credentials: Data("{}".utf8))

        mgr.migrateToIsolatedCredentialsIfNeeded()
        let dirsAfterFirst = fs.created.count
        // User authenticates after migration.
        mgr.markAuthenticated(mgr.accounts[0].id)

        mgr.migrateToIsolatedCredentialsIfNeeded()  // second run must be a no-op

        #expect(mgr.needsReauth(mgr.accounts[0]) == false)
        #expect(fs.created.count == dirsAfterFirst)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ACI_\(UUID().uuidString)")!
    }

    private func makeManager(fs: FSDouble, bridge: CountingSystemKeychainBridge) -> AccountManager {
        AccountManager(
            store: InMemoryCredentialStore(),
            systemBridge: bridge,
            defaults: makeDefaults(),
            fileExists: { fs.exists($0) },
            ensureDirectory: { try fs.ensure($0) }
        )
    }
}

/// In-memory filesystem double: records which paths "exist" and which dirs were
/// created, so needs-reauth / migration logic is testable without real FS.
@MainActor
final class FSDouble {
    var present: Set<String> = []
    var created: [String] = []

    func exists(_ path: String) -> Bool { present.contains(path) }
    func ensure(_ path: String) throws {
        created.append(path)
        present.insert(path)
    }
}

/// Read-only `SystemKeychainBridge` double that counts every interaction. Any
/// nonzero count after an account switch/remove means Logos touched the shared
/// system entry — exactly what PsychQuant/logos#12 forbids.
@MainActor
final class CountingSystemKeychainBridge: SystemKeychainBridge {
    private(set) var readCount = 0
    private(set) var existsCount = 0

    func read() throws -> Data? {
        readCount += 1
        return nil
    }

    func exists() -> Bool {
        existsCount += 1
        return false
    }
}
