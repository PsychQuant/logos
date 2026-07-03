import Foundation
import Testing
@testable import MultiStatsCore

@Suite("AccountDiscovery")
struct AccountDiscoveryTests {
    /// Builds a fake home dir:
    /// - ~/.claude + ~/.claude.json            (default account, sibling layout)
    /// - ~/.logos/accounts/AAA/.claude/.claude.json   (active Logos account)
    /// - ~/.logos/accounts/BBB/.claude                (shell — empty, must be filtered)
    /// - ~/.logos/accounts/CCC                        (shell — no .claude at all)
    private func makeFixtureHome() throws -> URL {
        let home = try makeTempDir()
        let fm = FileManager.default

        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"oauthAccount": {"displayName": "Default", "emailAddress": "d@example.com"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))

        let active = home.appendingPathComponent(".logos/accounts/AAA/.claude")
        try fm.createDirectory(at: active, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount": {"displayName": "Logos A", "userRateLimitTier": "max_5x"}}"#.utf8)
            .write(to: active.appendingPathComponent(".claude.json"))

        try fm.createDirectory(
            at: home.appendingPathComponent(".logos/accounts/BBB/.claude"),
            withIntermediateDirectories: true)
        try fm.createDirectory(
            at: home.appendingPathComponent(".logos/accounts/CCC"),
            withIntermediateDirectories: true)

        return home
    }

    @Test("discovers default + active Logos accounts, filters shells")
    func discoversAndFilters() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let accounts = AccountDiscovery.discover(home: home)

        #expect(accounts.count == 2)
        let defaults = accounts.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(defaults.first?.identity?.displayName == "Default")

        let logos = accounts.filter { !$0.isDefault }
        #expect(logos.count == 1)
        #expect(logos.first?.identity?.displayName == "Logos A")
        #expect(logos.first?.identity?.userRateLimitTier == "max_5x")
    }

    @Test("empty home yields no accounts, no crash")
    func emptyHome() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AccountDiscovery.discover(home: home).isEmpty)
    }

    @Test("default account listed before Logos accounts")
    func defaultFirst() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let accounts = AccountDiscovery.discover(home: home)
        #expect(accounts.first?.isDefault == true)
    }
}
