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

    // MARK: - Per-label UTF-8 byte cap (#62)
    //
    // Swift `String.count` measures extended grapheme clusters, not bytes. One
    // cluster can carry unbounded combining scalars (a "zalgo" base + N combining
    // marks, or a long ZWJ emoji sequence), so a within-30-grapheme label can smuggle
    // hundreds of KB into the persisted index — which #61's whole-file cap then drops
    // as data loss. The mutation gate REJECTS an over-byte label; construction CLAMPS it,
    // always on a grapheme-cluster boundary so no cluster is split.

    /// One base char + 4000 combining marks: a single grapheme cluster, ~8 KB of UTF-8.
    private static let zalgoLabel = "a" + String(repeating: "\u{0301}", count: 4000)
    /// 30 ZWJ family emoji: 30 grapheme clusters, 25 UTF-8 bytes each = 750 bytes.
    private static let fatEmojiLabel = String(repeating: "👨‍👩‍👧‍👦", count: 30)

    @Test("validate rejects a 1-grapheme label that exceeds the byte cap (#62)") @MainActor
    func validateRejectsZalgoBytes() {
        #expect(Self.zalgoLabel.count == 1)          // passes the 30-grapheme gate
        #expect(Self.zalgoLabel.utf8.count > 256)    // but blows the byte budget
        #expect(throws: Account.ValidationError.labelTooLong) {
            _ = try Account.validate(label: Self.zalgoLabel)
        }
    }

    @Test("validate rejects 30 ZWJ-emoji clusters that exceed the byte cap (#62)") @MainActor
    func validateRejectsFatEmojiBytes() {
        #expect(Self.fatEmojiLabel.count == 30)      // exactly at the grapheme cap
        #expect(Self.fatEmojiLabel.utf8.count == 750)
        #expect(throws: Account.ValidationError.labelTooLong) {
            _ = try Account.validate(label: Self.fatEmojiLabel)
        }
    }

    @Test("init clamps an over-byte label to the byte cap on a grapheme boundary (#62)")
    func initClampsFatEmojiToByteCap() {
        let acc = Account(id: "x", label: Self.fatEmojiLabel)
        #expect(acc.label.utf8.count <= Account.maxLabelUTF8Bytes)              // clamped under budget
        #expect(acc.label == String(repeating: "👨‍👩‍👧‍👦", count: 10))          // 10 whole clusters, 250 bytes
        #expect(String(Array(acc.label)) == acc.label)                          // round-trips as whole Characters
    }

    @Test("init byte-clamp lands on a grapheme boundary, never mid-scalar (CJK) (#62)")
    func initByteClampCJKBoundary() {
        // 100 CJK chars: 3 UTF-8 bytes each = 300 bytes, over the byte cap. Since 256 is not a
        // multiple of 3, a raw `utf8.prefix(256)` would split the 86th char mid-scalar. The
        // cluster-aware clamp instead drops it whole → 85 chars, 255 bytes.
        let acc = Account(id: "x", label: String(repeating: "字", count: 100))
        #expect(acc.label.utf8.count <= Account.maxLabelUTF8Bytes)
        #expect(acc.label.utf8.count == 255)                                    // 85 x 3 — not 256 (no mid-scalar cut)
        #expect(acc.label.count == 85)
        #expect(String(Array(acc.label)) == acc.label)                          // whole Characters, no split
    }

    @Test("validate trims a trailing newline (unified .whitespacesAndNewlines) (#62)") @MainActor
    func validateTrimsNewline() throws {
        #expect(try Account.validate(label: "work\n") == "work")
    }

    @Test("init trims a trailing newline (unified .whitespacesAndNewlines) (#62)")
    func initTrimsNewline() {
        #expect(Account(id: "x", label: "work\n").label == "work")
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

    // #55: usageConfigDir is the account's REAL claude config dir — where the usage
    // layer reads its transcript / keys its keychain lookup. For the system-default
    // account this is the bare `~/.claude` (it spawns with no CLAUDE_CONFIG_DIR and
    // never materializes its per-account dir), NOT the configDirPath the isolation
    // path uses.
    @Test("usageConfigDir is ~/.claude for a system-default account (#55)")
    func usageConfigDirSystemDefault() {
        let acc = Account(id: "main", label: "Main", isSystemDefault: true)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        #expect(acc.usageConfigDir == home)
        #expect(!acc.usageConfigDir.contains("/.logos/accounts/"))
    }

    @Test("usageConfigDir equals configDirPath for an isolated account (#55)")
    func usageConfigDirIsolated() {
        let acc = Account(id: "abc", label: "work")
        #expect(acc.usageConfigDir == acc.configDirPath)
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

    // #56: the system-default account has a stable well-known id so registry
    // uniqueness keys off id, not the mutable label.
    @Test("systemDefaultID is a stable well-known id (#56)")
    func systemDefaultIDConstant() {
        #expect(Account.systemDefaultID == "system-default")
    }
}

/// Per-account gateway upstream (spec 2026-07-31).
@Suite("Account upstream")
struct AccountUpstreamTests {

    @Test("defaults to nil")
    func upstreamDefaultsToNil() {
        #expect(Account(label: "Work").upstream == nil)
    }

    @Test("round-trips through Codable")
    func roundTripsUpstream() throws {
        let account = Account(label: "Work", upstream: "https://gateway.example.com")
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        #expect(decoded.upstream == "https://gateway.example.com")
    }

    /// An index.json written before this field existed must still decode. A
    /// non-optional property here would throw and drop the ENTIRE registry — the
    /// same failure mode `isSystemDefault` was made optional to avoid.
    @Test("a legacy account without the field still decodes")
    func decodesLegacyAccountWithoutUpstream() throws {
        let legacy = #"{"id":"ACC-1","label":"Work","createdAt":0,"isSystemDefault":false}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(legacy.utf8))
        #expect(account.upstream == nil)
        #expect(account.id == "ACC-1")
        #expect(account.label == "Work")
    }

    /// The system-default account can carry an upstream in the model, but it is
    /// never routed through the pool — this pins the model as orthogonal to the
    /// pool's exclusion rule so the two cannot drift into contradicting each other.
    @Test("upstream is independent of isSystemDefault")
    func upstreamIndependentOfSystemDefault() {
        let main = Account(
            id: Account.systemDefaultID, label: "Main",
            isSystemDefault: true, upstream: "https://example.com")
        #expect(main.upstream == "https://example.com")
        #expect(main.spawnConfigDir == nil)
    }
}
