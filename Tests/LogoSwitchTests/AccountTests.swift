import Testing
import Foundation
import LogoSwitch

@Suite("Account", .serialized)
struct AccountTests {

    @Test("account has id + label + creation date")
    func basicShape() {
        let acc = Account(id: "abc123", label: "personal")
        #expect(acc.id == "abc123")
        #expect(acc.label == "personal")
        #expect(acc.createdAt.timeIntervalSinceNow < 0)
    }

    @Test("home directory path is per-account")
    func homeDirectory() {
        let acc = Account(id: "abc", label: "x")
        #expect(acc.homeDirectoryPath.hasSuffix("/.logos/accounts/abc"))
    }

    @Test("label trims whitespace")
    func labelTrim() {
        let acc = Account(id: "x", label: "  work  ")
        #expect(acc.label == "work")
    }

    @Test("label rejects empty after trim") @MainActor
    func labelEmpty() {
        #expect(throws: Account.ValidationError.emptyLabel) {
            _ = try Account.validate(label: "   ")
        }
    }

    @Test("label rejects > 30 chars") @MainActor
    func labelTooLong() {
        let long = String(repeating: "a", count: 31)
        #expect(throws: Account.ValidationError.labelTooLong) {
            _ = try Account.validate(label: long)
        }
    }

    // MARK: - System-default (main) account (#54)

    @Test("isSystemDefault defaults to false")
    func isSystemDefaultDefault() {
        let acc = Account(id: "abc", label: "work")
        #expect(acc.isSystemDefault == false)
    }

    @Test("spawnConfigDir is nil for a system-default account")
    func spawnConfigDirSystemDefault() {
        let acc = Account(id: "main", label: "Main", isSystemDefault: true)
        #expect(acc.spawnConfigDir == nil)
    }

    @Test("spawnConfigDir equals configDirPath for an isolated account")
    func spawnConfigDirIsolated() {
        let acc = Account(id: "abc", label: "work")
        #expect(acc.spawnConfigDir == acc.configDirPath)
    }

    @Test("configDirPath is unchanged for a system-default account (still the mkdir target)")
    func configDirPathUnchangedForSystemDefault() {
        let acc = Account(id: "main", label: "Main", isSystemDefault: true)
        #expect(acc.configDirPath.hasSuffix("/.logos/accounts/main/.claude"))
    }

    @Test("Codable round-trip carries isSystemDefault")
    func codableRoundTrip() throws {
        let acc = Account(id: "main", label: "Main", isSystemDefault: true)
        let data = try JSONEncoder().encode(acc)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        #expect(decoded.isSystemDefault == true)
    }

    @Test("legacy JSON without isSystemDefault decodes as false")
    func codableLegacyDefault() throws {
        // an account persisted before isSystemDefault existed
        let legacy = #"{"id":"x","label":"work","createdAt":0}"#
        let decoded = try JSONDecoder().decode(Account.self, from: Data(legacy.utf8))
        #expect(decoded.isSystemDefault == false)
    }
}
