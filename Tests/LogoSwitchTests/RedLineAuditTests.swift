import Foundation
import Testing
import Yams

/// The structural red-line guard for LogoSwitch (#34).
///
/// LogoSwitch must remain a launcher, not a credential manager. The strongest,
/// false-positive-free invariant is "the target does not import `Security`" — no
/// Security framework means `SecItemCopyMatching`/`SecItemAdd`/… are a compile
/// error, so no keychain read/write is even expressible. This test enforces that
/// invariant plus the `/usr/bin/security` shell-out forms (better-agent-terminal's
/// anti-pattern) across every source file in the module.
///
/// It scans `Sources/LogoSwitch/**/*.swift` with comments stripped (so a token
/// appearing only in a doc comment is allowed — explaining what we DON'T do is
/// fine; doing it is not). Added at Step 2 (empty target) so it guards every file
/// from the moment it lands, per the red-line reviewer's must-fix.
@Suite struct RedLineAuditTests {

    /// Tokens that may never appear in compiled LogoSwitch code. Each is an
    /// "attack form" — the act of touching a credential, not a mention of it.
    static let forbidden = [
        "import Security",        // links the keychain framework → SecItem* becomes callable
        "SecItem",                // SecItemCopyMatching/Add/Update/Delete
        "find-generic-password",  // `security find-generic-password` (BAT read)
        "add-generic-password",   // `security add-generic-password` (BAT write)
        "/usr/bin/security"       // the security(1) shell-out binary
    ]

    @Test func logoSwitchSourcesContainNoCredentialAccess() throws {
        let sourcesDir = Self.moduleSourcesDirectory()
        let swiftFiles = try Self.swiftFiles(in: sourcesDir)
        #expect(!swiftFiles.isEmpty, "expected at least one .swift file under \(sourcesDir.path)")

        for file in swiftFiles {
            let raw = try String(contentsOf: file, encoding: .utf8)
            let code = Self.strippingComments(raw)
            for token in Self.forbidden {
                #expect(
                    !code.contains(token),
                    "RED-LINE VIOLATION: \(file.lastPathComponent) contains '\(token)' in code (not a comment). LogoSwitch must never touch credentials."
                )
            }
        }
    }

    // MARK: - project.yml red-line guard (#66)

    /// Precise **link-form** tokens that would wire a keychain-exposing system
    /// framework into the `LogoSwitch` XcodeGen target. Each appears only in an
    /// actual link declaration — an `sdk:` dependency entry or an `-framework`
    /// linker flag — never in prose. `LocalAuthentication` is the sibling
    /// keychain/biometric framework, barred for the same reason. Scanned against a
    /// *structurally resolved* serialization of the target (`logoSwitchLinkSurface`),
    /// so aliases and array-form flags are normalized before the `contains` check.
    static let forbiddenProjectYmlLinkForms = [
        "Security.framework",        // - sdk: Security.framework
        "sdk: Security",             // - sdk: Security (extension-less form)
        "-framework Security",       // OTHER_LDFLAGS: "-framework Security"
        "-weak_framework Security",  // weak-link variant
        "LocalAuthentication",       // LAContext / biometric keychain gate
    ]

    /// The source-level scan above has a build-graph blind spot: since #60,
    /// `project.yml` declares `LogoSwitch` as an explicit XcodeGen
    /// `type: framework` target with its own `dependencies:`/`settings:`. A
    /// system-framework link added there (`- sdk: Security.framework`,
    /// `OTHER_LDFLAGS: -framework Security`) would make `SecItem*` callable from
    /// LogoSwitch with zero `import Security` in any `.swift` file — invisible to
    /// `logoSwitchSourcesContainNoCredentialAccess`.
    ///
    /// #66 round-2: the earlier line-heuristic scan of the extracted target block
    /// had two proven bypasses (security lens; PoCs at /tmp/xcodegen_duptest and
    /// /tmp/xcodegen_anchortest):
    ///   (a) a DUPLICATE top-level `LogoSwitch:` key — XcodeGen takes last-wins, but
    ///       the text scan read the first (clean) block; and
    ///   (b) YAML ANCHOR/ALIAS indirection — a top-level anchor holding
    ///       `-framework Security` aliased into the target's `OTHER_LDFLAGS`, absent
    ///       from any literal text inside the target block.
    /// This test now parses `project.yml` STRUCTURALLY with Yams (which resolves
    /// aliases + merge keys at load), navigates to `targets.LogoSwitch`, and scans a
    /// normalized serialization of that resolved subtree — closing (b). Vector (a) is
    /// closed by an explicit duplicate-key scan (`targetKeyCount`): Yams 5.4.0 throws
    /// `duplicatedKeysInMapping` on duplicate keys, but the guard must not depend on
    /// the parser's dup policy, so raw text is scanned for a repeated `LogoSwitch:`
    /// target key independently.
    @Test func projectYmlDoesNotLinkSecurityIntoLogoSwitch() throws {
        let yaml = try String(contentsOf: Self.projectYmlURL(), encoding: .utf8)

        // GREEN, vector (a): the real project.yml declares LogoSwitch exactly once.
        #expect(
            Self.targetKeyCount(named: "LogoSwitch", in: yaml) == 1,
            "project.yml must declare the LogoSwitch target exactly once (a duplicate key is the XcodeGen last-wins injection vector, #66)."
        )

        // GREEN, vector (b) + direct link: the resolved LogoSwitch subtree links no
        // keychain-exposing framework.
        let surface = try Self.logoSwitchLinkSurface(in: yaml)
        for token in Self.forbiddenProjectYmlLinkForms {
            #expect(
                !surface.contains(token),
                "RED-LINE VIOLATION: project.yml's LogoSwitch target links '\(token)'. LogoSwitch must never link a keychain-exposing framework (#34/#66)."
            )
        }

        // Detector sanity — synthetic REDs. Without these a broken scan passes
        // vacuously. Each is a form the guard MUST flag.

        // (a) DUPLICATE top-level LogoSwitch key (XcodeGen last-wins; the malicious
        // second block carries the Security link). PoC: /tmp/xcodegen_duptest. Only
        // the raw-text dup scan sees this — feeding it to Yams would throw.
        let dupInjected = [
            "targets:",
            "  LogoSwitch:",
            "    type: framework",
            "    sources: [Sources]",
            "  LogoSwitch:",
            "    type: framework",
            "    settings:",
            "      base:",
            "        OTHER_LDFLAGS: \"-framework Security\"",
        ].joined(separator: "\n")
        #expect(
            Self.targetKeyCount(named: "LogoSwitch", in: dupInjected) == 2,
            "duplicate-key vector (a) not detected — a last-wins LogoSwitch injection would slip past the guard"
        )

        // (b) ANCHOR/ALIAS indirection: a top-level anchor holds the Security linker
        // flag, aliased into OTHER_LDFLAGS — no literal Security token inside the
        // LogoSwitch block. Yams resolves the alias at load. PoC: /tmp/xcodegen_anchortest.
        let aliasInjected = [
            "settings:",
            "  base:",
            "    SEC_FLAG: &secFlag \"-framework Security\"",
            "targets:",
            "  LogoSwitch:",
            "    type: framework",
            "    settings:",
            "      base:",
            "        OTHER_LDFLAGS: *secFlag",
        ].joined(separator: "\n")
        let aliasSurface = try Self.logoSwitchLinkSurface(in: aliasInjected)
        #expect(
            aliasSurface.contains("-framework Security"),
            "alias vector (b) not resolved — the guard would miss an aliased Security link"
        )

        // Direct injection through both channels, incl. the ARRAY form of
        // OTHER_LDFLAGS (["-framework", "Security"]) — the resolved-array normalize
        // must join it back to a scannable "-framework Security".
        let directInjected = [
            "targets:",
            "  LogoSwitch:",
            "    type: framework",
            "    dependencies:",
            "      - target: LogosAccounts",
            "      - sdk: Security.framework",
            "    settings:",
            "      base:",
            "        OTHER_LDFLAGS: [\"-framework\", \"Security\"]",
            "  Logos:",
            "    type: application",
        ].joined(separator: "\n")
        let directSurface = try Self.logoSwitchLinkSurface(in: directInjected)
        #expect(
            directSurface.contains("Security.framework"),
            "detector failed to flag an injected 'sdk: Security.framework' dependency"
        )
        #expect(
            directSurface.contains("-framework Security"),
            "detector failed to flag an array-form '-framework Security' linker flag (array normalize broken)"
        )

        // Isolation: a Security link in a SIBLING target must NOT leak into the
        // LogoSwitch surface (structural navigation targets LogoSwitch precisely,
        // replacing the old block-boundary heuristic).
        let siblingInjected = [
            "targets:",
            "  LogoSwitch:",
            "    type: framework",
            "    dependencies:",
            "      - target: LogosAccounts",
            "  Logos:",
            "    type: application",
            "    settings:",
            "      base:",
            "        OTHER_LDFLAGS: \"-framework Security\"",
        ].joined(separator: "\n")
        let siblingSurface = try Self.logoSwitchLinkSurface(in: siblingInjected)
        #expect(
            !siblingSurface.contains("-framework Security"),
            "structural navigation leaked a sibling target's Security link into the LogoSwitch surface"
        )
    }

    // MARK: - project.yml structural helpers (#66)

    /// `<repo>/project.yml`, derived from this test file's location (up 3 to the
    /// repo root, same shape as `moduleSourcesDirectory()`).
    static func projectYmlURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // LogoSwitchTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("project.yml", isDirectory: false)
    }

    /// Number of times `name` appears as a top-level XcodeGen target key (a `<name>:`
    /// line indented exactly two spaces — a direct child of `targets:`), ignoring
    /// `#` comment lines. `> 1` is the duplicate-key injection vector (#66 (a)):
    /// XcodeGen resolves duplicates last-wins, so a second `LogoSwitch:` block could
    /// carry a Security link. Yams 5.4.0 throws on duplicate keys, but the guard
    /// scans raw text so it never depends on that parser behavior.
    static func targetKeyCount(named name: String, in yaml: String) -> Int {
        yaml.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return false }
                // exactly 2-space indent: the char after "  " is the key's first
                // letter, so a deeper-indented `    LogoSwitch:` never matches.
                return line.hasPrefix("  \(name):")
            }
            .count
    }

    /// A normalized, structurally-resolved serialization of the `targets.LogoSwitch`
    /// subtree, ready for a `contains(token)` link scan. Yams resolves anchors,
    /// aliases, and merge keys at load (#66 (b)); `flatten` then renders the subtree
    /// as `key: value` text and joins string arrays with spaces so an array-form
    /// linker flag (`["-framework", "Security"]`) becomes the scannable
    /// `-framework Security`. Returns `""` when the target is absent.
    static func logoSwitchLinkSurface(in yaml: String) throws -> String {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any],
              let targets = root["targets"] as? [String: Any],
              let logoSwitch = targets["LogoSwitch"] else {
            return ""
        }
        return Self.flatten(logoSwitch)
    }

    /// Recursively renders a resolved YAML value as flat text. Mappings render as
    /// `key: value` pairs, sequences of scalars join with spaces (so an array-form
    /// linker flag is scannable as one token), nested sequences/mappings recurse.
    /// The output is for substring token matching only — key order is irrelevant.
    static func flatten(_ node: Any) -> String {
        switch node {
        case let s as String:
            return s
        case let arr as [Any]:
            return arr.map { Self.flatten($0) }.joined(separator: " ")
        case let dict as [String: Any]:
            return dict.map { "\($0.key): \(Self.flatten($0.value))" }.joined(separator: " ")
        case let dict as [AnyHashable: Any]:
            return dict.map { "\(String(describing: $0.key)): \(Self.flatten($0.value))" }.joined(separator: " ")
        default:
            return String(describing: node)
        }
    }

    // MARK: - source-scan helpers

    /// `<repo>/Sources/LogoSwitch`, derived from this test file's location:
    /// …/Tests/LogoSwitchTests/RedLineAuditTests.swift → up 3 → repo root.
    static func moduleSourcesDirectory(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // LogoSwitchTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/LogoSwitch", isDirectory: true)
    }

    static func swiftFiles(in dir: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Removes `/* … */` block comments and full-line `//` / `///` comments — the
    /// two forms the moved files use for the explanatory red-line docstrings the
    /// reviewer flagged as false-positive sources. String literals are preserved,
    /// so a `/usr/bin/security` literal or a `find-generic-password` argument is
    /// still caught.
    static func strippingComments(_ source: String) -> String {
        var s = source
        if let re = try? NSRegularExpression(pattern: "/\\*.*?\\*/", options: [.dotMatchesLineSeparators]) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
