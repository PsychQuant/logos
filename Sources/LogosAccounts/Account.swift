import Foundation

public struct Account: Identifiable, Hashable, Sendable, Codable {

    /// The stable, well-known id of the system-default ("main") account (#56).
    /// Registry uniqueness for the system-default keys off this id, NOT the
    /// mutable label — so a "Main" system-default coexists with an isolated
    /// "Main". Safe as a fixed id because the system-default's `spawnConfigDir`
    /// is nil, so the id is never used as a spawn config-dir path for it.
    public static let systemDefaultID = "system-default"

    /// Stable per-account identifier. Used as the per-account **config-dir** name
    /// (the `CLAUDE_CONFIG_DIR` target), NOT the process `HOME` — Logos never
    /// overrides `HOME` (PsychQuant/logos#21), since that would move the login
    /// keychain lookup and break claude's credential read.
    public let id: String
    public let label: String  // user-visible name; editable
    public let createdAt: Date

    /// When true, this is the "main" account that reuses the system `~/.claude`
    /// login: it spawns claude with NO `CLAUDE_CONFIG_DIR` override
    /// (`spawnConfigDir == nil`), so claude falls through to the default
    /// `~/.claude` + the bare `Claude Code-credentials` keychain entry. Zero
    /// token touch — Logos never reads a credential; it just declines to isolate
    /// this one account (PsychQuant/logos#54).
    public let isSystemDefault: Bool

    /// Per-account gateway upstream (spec 2026-07-31). `nil` means the default
    /// `https://api.anthropic.com`. When set, the gateway failure policy becomes
    /// FAIL-CLOSED: silently falling back to the default upstream would send traffic
    /// somewhere the operator did not direct it, which is a routing-policy violation
    /// rather than a degradation.
    ///
    /// Orthogonal to `isSystemDefault` — the model permits either combination; it is
    /// `GatewayPool` that declines to route the system-default account at all.
    public let upstream: String?

    public init(
        id: String = UUID().uuidString,
        label: String,
        createdAt: Date = Date(),
        isSystemDefault: Bool = false,
        upstream: String? = nil
    ) {
        self.id = id
        self.label = Account.byteBoundedLabel(label)   // #62: trim + byte cap (see byteBoundedLabel)
        self.createdAt = createdAt
        self.isSystemDefault = isSystemDefault
        self.upstream = upstream
    }

    /// Custom decode so accounts persisted before `isSystemDefault` existed (no
    /// such key) decode as `false` rather than throwing (#54). `encode(to:)`
    /// stays synthesized — it uses the same `CodingKeys` and emits all four fields.
    enum CodingKeys: String, CodingKey {
        case id, label, createdAt, isSystemDefault, upstream
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.isSystemDefault = try c.decodeIfPresent(Bool.self, forKey: .isSystemDefault) ?? false
        // Same reason as `isSystemDefault` above: an index.json written before this
        // field existed must still decode, or one missing key drops the whole registry.
        self.upstream = try c.decodeIfPresent(String.self, forKey: .upstream)
    }

    /// The account's Logos-internal data directory (`~/.logos/accounts/<id>`).
    /// This is the parent of the claude config dir — it is NOT the process `HOME`
    /// (#21); the spawned claude inherits the real `HOME` and only its
    /// `CLAUDE_CONFIG_DIR` points here.
    public var homeDirectoryPath: String {
        AccountsRoot.url().appendingPathComponent(id).path
    }

    /// Per-account claude config directory. claude keys its credential Keychain
    /// service name on this directory (service `Claude Code-credentials-<hash>`,
    /// where `<hash>` is the first 8 hex chars of `sha256` over the NFC-normalized
    /// path), so giving each account its own config dir isolates its credentials
    /// into claude's own per-directory Keychain item — Logos never writes the
    /// shared `Claude Code-credentials` entry (PsychQuant/logos#12).
    public var configDirPath: String {
        "\(homeDirectoryPath)/.claude"
    }

    /// The config dir to spawn claude with. `nil` for a system-default account
    /// (#54) → `ClaudeConfigEnvironment.apply` sets no `CLAUDE_CONFIG_DIR`, so
    /// claude uses the system `~/.claude`. For an isolated account it is
    /// `configDirPath`. `configDirPath` itself stays non-optional — it is still
    /// the `materializeHomeTree` mkdir target for isolated accounts.
    public var spawnConfigDir: String? {
        isSystemDefault ? nil : configDirPath
    }

    /// #55: the account's REAL claude config dir — where the usage layer reads its
    /// session transcript AND keys its Keychain lookup. For the system-default
    /// account this is the bare `~/.claude` (it spawns with no `CLAUDE_CONFIG_DIR`
    /// and never materializes `configDirPath`), so usage must read there, not the
    /// per-account isolation path. For an isolated account it IS `configDirPath`.
    /// Distinct from `spawnConfigDir` (which is `nil` for the system-default,
    /// meaning "no override" — unusable as a concrete dir); this always resolves to
    /// a real directory.
    public var usageConfigDir: String {
        isSystemDefault
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
            : configDirPath
    }

    public enum ValidationError: Error, Equatable {
        case emptyLabel
        case labelTooLong
        case duplicateLabel
        /// #57 F1: an account with this id already exists (global id-uniqueness).
        case duplicateID
        /// #57 F2: a system-default account already exists (at most one).
        case duplicateSystemDefault
        /// #57 round-2: reserved-id ownership — the fixed `systemDefaultID` may
        /// only (and must only) be held by the system-default account.
        case reservedID
        /// #61: the id is a CONFIG-DIR PATH COMPONENT — malformed format
        /// (traversal, control chars, empty, over-long) is a security boundary
        /// violation, not just bad data.
        case invalidID
    }

    /// #61: id format — the id becomes a path component
    /// (`~/.logos/accounts/<id>/.claude` → the spawned claude's
    /// `CLAUDE_CONFIG_DIR`), so its format IS a security boundary: ASCII
    /// letters/digits/hyphen only, 1–64 chars. Covers every legitimate producer
    /// (UUID strings, the fixed `systemDefaultID`) and excludes traversal
    /// (`/`, `..` needs `.`), empties, and control characters.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    // MARK: - Label normalization (single source of truth) — #62

    /// Max label size in extended grapheme clusters (Swift `Character`s).
    public static let maxLabelGraphemes = 30

    /// Max label size in UTF-8 bytes. Grapheme count alone does NOT bound the
    /// persisted byte size — one cluster can carry an unbounded number of combining
    /// scalars (a "zalgo" base + N combining marks, or a long ZWJ emoji sequence), so a
    /// within-30-grapheme label can smuggle hundreds of KB into `index.json`. Labels are
    /// therefore ALSO capped by byte size to keep the index under the whole-file cap
    /// (`AccountRegistry.maxIndexBytes`, #61) — otherwise one fat label could push the
    /// index past that cap and drop the ENTIRE registry on the next load.
    public static let maxLabelUTF8Bytes = 256

    /// The one trim set every label path uses. #62 resolved the earlier drift where the
    /// mutation gate trimmed `.whitespaces` while the load-repair path trimmed
    /// `.whitespacesAndNewlines` — a newline only ever reaches a label via the decode path,
    /// and the two definitions of "trimmed" disagreed. `.whitespacesAndNewlines` is the
    /// superset, so it is the single definition.
    static let labelTrimSet: CharacterSet = .whitespacesAndNewlines

    /// Truncate `s` to at most `maxBytes` UTF-8 bytes WITHOUT splitting a grapheme
    /// cluster: accumulate whole `Character`s until the next would exceed the budget,
    /// then stop. A raw `utf8.prefix(maxBytes)`/scalar cut could land inside a multi-byte
    /// scalar or inside a ZWJ sequence, producing a replacement char / a broken cluster.
    static func clampedToUTF8Bytes(_ s: String, _ maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var result = ""
        var used = 0
        for ch in s {
            let chBytes = String(ch).utf8.count
            if used + chBytes > maxBytes { break }
            result.append(ch)
            used += chBytes
        }
        return result
    }

    /// `init(label:)`'s clamp: trim (`labelTrimSet`) + the BYTE cap only, on a grapheme
    /// boundary. Deliberately NOT grapheme-capped: `AccountRegistry.normalize()`'s
    /// uniquify sweep (#59) constructs an `Account` with a `"<label> (recovered)"` label
    /// that can exceed `maxLabelGraphemes` while carrying only a handful of bytes, and
    /// relies on `init` preserving it — a grapheme clamp here would strip the suffix and
    /// reopen the exact-cap label collision that sweep just resolved (breaking #59's
    /// convergence). The grapheme cap is not a persisted-size boundary (the byte cap is),
    /// and the two real over-length gates still apply: the mutation gate (`validate`)
    /// throws on >`maxLabelGraphemes`, and `normalize`'s cleanup pass (`clampedLabel`)
    /// grapheme-clamps on load. So `init` only needs to bound bytes.
    static func byteBoundedLabel(_ raw: String) -> String {
        clampedToUTF8Bytes(raw.trimmingCharacters(in: labelTrimSet), maxLabelUTF8Bytes)
    }

    /// #62 round-2: build a `"<base> <suffix>"` label whose SUFFIX is guaranteed to survive
    /// `init(label:)`'s byte cap. The uniquify sweeps (`AccountRegistry.normalize()` phase 3
    /// and `uniqueIsolatedLabel`) append a `" (recovered)"` disambiguator to a colliding
    /// label, then hand the result to `Account.init`. When the base sits at/near
    /// `maxLabelUTF8Bytes`, `byteBoundedLabel`'s cluster-boundary clamp truncates the suffix
    /// entirely (the base is one whole cluster over budget) — silently re-creating the exact
    /// duplicate the sweep just resolved, whose net label diff is then zero (so `changed`
    /// never fires and the repair never persists). Clamping the BASE first, to leave room for
    /// the suffix, guarantees the disambiguator is never cut. The trailing `byteBoundedLabel`
    /// makes the return value EXACTLY what `init(label:)` stores (idempotent), so callers can
    /// uniqueness-check and bookkeep on the realized label. Deliberately NOT grapheme-capped
    /// (mirrors `byteBoundedLabel`): the suffix's grapheme-cap tug-of-war with the cleanup
    /// clamp is what #59's net-change convergence relies on.
    static func labelWithSuffix(base: String, suffix: String) -> String {
        let budget = maxLabelUTF8Bytes - suffix.utf8.count
        let clampedBase = budget > 0 ? clampedToUTF8Bytes(base, budget) : ""
        return byteBoundedLabel(clampedBase + suffix)
    }

    /// The load-time repair clamp: trim (`labelTrimSet`), then clamp to BOTH
    /// `maxLabelGraphemes` and `maxLabelUTF8Bytes`, each on a grapheme-cluster boundary.
    /// No placeholder and no throw — used by `AccountRegistry.normalize()` phase 3. May
    /// return an empty string for an all-whitespace input; the empty→placeholder policy
    /// is the repair path's concern, applied by the caller, not the clamp's.
    static func clampedLabel(_ raw: String) -> String {
        var label = raw.trimmingCharacters(in: labelTrimSet)
        if label.count > maxLabelGraphemes { label = String(label.prefix(maxLabelGraphemes)) }
        if label.utf8.count > maxLabelUTF8Bytes { label = clampedToUTF8Bytes(label, maxLabelUTF8Bytes) }
        return label
    }

    /// Validate label only (duplicate-check requires AccountManager). The user-facing
    /// mutation gate: it THROWS on an over-budget label rather than clamping, so the user
    /// learns their label was rejected. Shares `labelTrimSet` and the cap constants with
    /// `clampedLabel` so "what a valid, bounded label is" is defined once. An over-byte
    /// label reuses `labelTooLong` (both caps are "the label is too big") — no separate
    /// case, to keep the enum non-breaking for exhaustive `switch` sites.
    public static func validate(label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: labelTrimSet)
        if trimmed.isEmpty { throw ValidationError.emptyLabel }
        if trimmed.count > maxLabelGraphemes || trimmed.utf8.count > maxLabelUTF8Bytes {
            throw ValidationError.labelTooLong
        }
        return trimmed
    }
}
