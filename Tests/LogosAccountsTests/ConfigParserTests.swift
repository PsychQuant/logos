import Foundation
import Testing
@testable import MultiStatsCore

@Suite("ConfigParser")
struct ConfigParserTests {
    // MARK: identity(fromConfigData:)

    @Test("parses oauthAccount subset from well-formed config JSON")
    func parsesIdentity() throws {
        let json = """
        {
          "someUnrelatedKey": 42,
          "oauthAccount": {
            "accountUuid": "abc-123",
            "displayName": "Che",
            "emailAddress": "che@example.com",
            "organizationName": "Example Org",
            "userRateLimitTier": "max_20x",
            "unknownFutureField": {"nested": true}
          }
        }
        """.data(using: .utf8)!

        let identity = try #require(ConfigParser.identity(fromConfigData: json))
        #expect(identity.accountUuid == "abc-123")
        #expect(identity.displayName == "Che")
        #expect(identity.emailAddress == "che@example.com")
        #expect(identity.organizationName == "Example Org")
        #expect(identity.userRateLimitTier == "max_20x")
        #expect(identity.seatTier == nil)
    }

    @Test("missing oauthAccount yields nil, not a crash")
    func missingOAuthAccount() {
        let json = #"{"projects": {}, "autoUpdates": true}"#.data(using: .utf8)!
        #expect(ConfigParser.identity(fromConfigData: json) == nil)
    }

    @Test("malformed JSON yields nil, not a crash")
    func malformedJSON() {
        let junk = "not json at all {{{".data(using: .utf8)!
        #expect(ConfigParser.identity(fromConfigData: junk) == nil)
    }

    // MARK: configJSONURL(for:)

    @Test("finds config JSON inside the config dir (Logos CLAUDE_CONFIG_DIR layout)")
    func findsInsideForm() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let inside = configDir.appendingPathComponent(".claude.json")
        try Data("{}".utf8).write(to: inside)

        #expect(ConfigParser.configJSONURL(for: configDir)?.path == inside.path)
    }

    @Test("finds config JSON as sibling of the config dir (default account layout)")
    func findsSiblingForm() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let sibling = root.appendingPathComponent(".claude.json")
        try Data("{}".utf8).write(to: sibling)

        #expect(ConfigParser.configJSONURL(for: configDir)?.path == sibling.path)
    }

    @Test("shell dir with no config JSON anywhere yields nil")
    func shellDir() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        #expect(ConfigParser.configJSONURL(for: configDir) == nil)
    }
}

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MultiStatsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
