import Foundation
import Testing
@testable import MultiStatsCore

@Suite("ClaudeKeychain")
struct ClaudeKeychainTests {
    // MARK: serviceName

    @Test("default account uses the bare service name")
    func defaultServiceName() {
        let dir = URL(fileURLWithPath: "/Users/anyone/.claude")
        #expect(ClaudeKeychain.serviceName(forConfigDir: dir, isDefault: true) == "Claude Code-credentials")
    }

    @Test("per-account service name appends sha256[:8] of the config dir path")
    func perAccountServiceName() {
        // Machine-independent vector: sha256("/home/test/.claude")[:8] == "4f77d40a"
        let dir = URL(fileURLWithPath: "/home/test/.claude")
        #expect(ClaudeKeychain.serviceName(forConfigDir: dir, isDefault: false)
            == "Claude Code-credentials-4f77d40a")
    }

    @Test("per-account suffix is 8 lowercase hex chars and path-sensitive")
    func suffixShapeAndSensitivity() {
        let a = ClaudeKeychain.serviceName(
            forConfigDir: URL(fileURLWithPath: "/a/.claude"), isDefault: false)
        let b = ClaudeKeychain.serviceName(
            forConfigDir: URL(fileURLWithPath: "/b/.claude"), isDefault: false)
        #expect(a != b)
        let suffix = a.replacingOccurrences(of: "Claude Code-credentials-", with: "")
        #expect(suffix.count == 8)
        #expect(suffix.allSatisfy { "0123456789abcdef".contains($0) })
    }

    // MARK: parseCredentials

    private static let validJSON = Data(#"""
    {
      "claudeAiOauth": {
        "accessToken": "tok-abc",
        "refreshToken": "ref-xyz",
        "expiresAt": 1751461200000,
        "scopes": ["user:inference"],
        "subscriptionType": "max",
        "rateLimitTier": "max_20x"
      }
    }
    """#.utf8)

    @Test("parses access token, expiry (ms → Date), and subscription type")
    func parsesCredentials() throws {
        let creds = try #require(ClaudeKeychain.parseCredentials(fromData: Self.validJSON))
        #expect(creds.accessToken == "tok-abc")
        #expect(creds.refreshToken == "ref-xyz")
        #expect(creds.subscriptionType == "max")
        // 1751461200000 ms == 1751461200 s
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1751461200))
    }

    @Test("missing claudeAiOauth yields nil")
    func missingOAuth() {
        #expect(ClaudeKeychain.parseCredentials(fromData: Data(#"{"other": 1}"#.utf8)) == nil)
    }

    @Test("empty access token yields nil")
    func emptyToken() {
        let json = Data(#"{"claudeAiOauth": {"accessToken": ""}}"#.utf8)
        #expect(ClaudeKeychain.parseCredentials(fromData: json) == nil)
    }

    @Test("malformed JSON yields nil, not a crash")
    func malformed() {
        #expect(ClaudeKeychain.parseCredentials(fromData: Data("not json {{{".utf8)) == nil)
    }

    @Test("missing expiresAt leaves date nil but still parses the token")
    func missingExpiry() throws {
        let json = Data(#"{"claudeAiOauth": {"accessToken": "t"}}"#.utf8)
        let creds = try #require(ClaudeKeychain.parseCredentials(fromData: json))
        #expect(creds.accessToken == "t")
        #expect(creds.expiresAt == nil)
    }

    // MARK: isExpired

    @Test("isExpired compares against expiry; unknown expiry is treated valid")
    func expiryLogic() {
        let expiry = Date(timeIntervalSince1970: 1000)
        let creds = StoredCredentials(accessToken: "t", expiresAt: expiry)
        #expect(creds.isExpired(asOf: Date(timeIntervalSince1970: 1001)) == true)
        #expect(creds.isExpired(asOf: Date(timeIntervalSince1970: 999)) == false)

        let noExpiry = StoredCredentials(accessToken: "t", expiresAt: nil)
        #expect(noExpiry.isExpired(asOf: Date(timeIntervalSince1970: 9_999_999)) == false)
    }
}

/// In-memory `KeychainReading` for tests — maps service name → raw data.
private struct StubKeychain: KeychainReading {
    let store: [String: Data]
    func readGenericPassword(service: String) -> Data? { store[service] }
}

@Suite("KeychainCredentialsReader")
struct KeychainCredentialsReaderTests {
    @Test("resolves the service name and parses the stored credentials")
    func readsAndParses() throws {
        let account = Account(
            configDir: URL(fileURLWithPath: "/home/test/.claude"),
            isDefault: false, identity: nil)
        let service = ClaudeKeychain.serviceName(
            forConfigDir: account.configDir, isDefault: account.isDefault)
        let json = Data(#"{"claudeAiOauth": {"accessToken": "tok-1"}}"#.utf8)

        let reader = KeychainCredentialsReader(keychain: StubKeychain(store: [service: json]))
        let creds = try #require(reader.credentials(for: account))
        #expect(creds.accessToken == "tok-1")
    }

    @Test("absent Keychain item yields nil, no crash")
    func absentItem() {
        let account = Account(
            configDir: URL(fileURLWithPath: "/home/test/.claude"),
            isDefault: false, identity: nil)
        let reader = KeychainCredentialsReader(keychain: StubKeychain(store: [:]))
        #expect(reader.credentials(for: account) == nil)
    }
}
