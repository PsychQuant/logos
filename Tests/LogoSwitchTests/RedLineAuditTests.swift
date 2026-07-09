import Foundation
import Testing

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
    /// linker flag — never in prose, so unlike a naive `contains("Security")`
    /// none of these trips on the `#` doc-comments at project.yml:62/74/94.
    /// `LocalAuthentication` is the sibling keychain/biometric framework, barred
    /// for the same reason.
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
    /// `logoSwitchSourcesContainNoCredentialAccess`. This test extracts the
    /// `LogoSwitch:` target block and asserts it links no keychain-exposing
    /// framework, keeping project.yml consistent with `Package.swift` (whose
    /// LogoSwitch target has no Security-linking product dependency).
    @Test func projectYmlDoesNotLinkSecurityIntoLogoSwitch() throws {
        let yaml = try String(contentsOf: Self.projectYmlURL(), encoding: .utf8)

        // GREEN: the real LogoSwitch block is clean today.
        let block = try #require(
            Self.targetBlock(named: "LogoSwitch", in: yaml),
            "expected a 'LogoSwitch:' target block in project.yml"
        )
        for token in Self.forbiddenProjectYmlLinkForms {
            #expect(
                !Self.blockLinksToken(block, token),
                "RED-LINE VIOLATION: project.yml's LogoSwitch target links '\(token)'. LogoSwitch must never link a keychain-exposing framework (#34/#66)."
            )
        }

        // Detector sanity: a synthetic LogoSwitch block that DOES inject a
        // Security link (both `sdk:` and `-framework` channels) must be flagged.
        // Without this a broken scan would pass vacuously — it also proves block
        // extraction stops at the sibling `Logos:` key rather than leaking into
        // the next target.
        let violating = [
            "  LogoSwitch:",
            "    type: framework",
            "    platform: macOS",
            "    dependencies:",
            "      - target: LogosAccounts",
            "      - sdk: Security.framework",
            "    settings:",
            "      base:",
            "        OTHER_LDFLAGS: \"-framework Security\"",
            "  Logos:",
            "    type: application",
        ].joined(separator: "\n")
        let syntheticBlock = try #require(Self.targetBlock(named: "LogoSwitch", in: violating))
        #expect(
            Self.blockLinksToken(syntheticBlock, "Security.framework"),
            "detector failed to flag an injected 'sdk: Security.framework' link — the guard would be a no-op"
        )
        #expect(
            Self.blockLinksToken(syntheticBlock, "-framework Security"),
            "detector failed to flag an injected '-framework Security' linker flag"
        )
        #expect(
            !syntheticBlock.contains("type: application"),
            "block extraction leaked past the LogoSwitch target into the sibling 'Logos:' key"
        )
    }

    // MARK: - helpers

    /// `<repo>/project.yml`, derived from this test file's location (up 3 to the
    /// repo root, same shape as `moduleSourcesDirectory()`).
    static func projectYmlURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // LogoSwitchTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("project.yml", isDirectory: false)
    }

    /// Extracts the 2-space-indented `<name>:` target block from a project.yml
    /// string: from the `^  <name>:` line up to (not including) the next block
    /// boundary — a sibling target key (`^  \S`) or a top-level key (`^\S`),
    /// ignoring `#` comment lines. Returns `nil` if the target is absent.
    static func targetBlock(named name: String, in yaml: String) -> String? {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("  \(name):") }) else {
            return nil
        }
        var block = [lines[start]]
        for line in lines[(start + 1)...] {
            if Self.isBlockBoundary(line) { break }
            block.append(line)
        }
        return block.joined(separator: "\n")
    }

    /// A line ends the current target block: either a top-level key (0 indent,
    /// non-comment) or a sibling target key (exactly 2-space indent, non-comment).
    /// Deeper-indented lines, blank lines, and `#` comments are never boundaries.
    static func isBlockBoundary(_ line: Substring) -> Bool {
        if let first = line.first, first != " ", first != "#" { return true }
        guard line.hasPrefix("  ") else { return false }
        let idx = line.index(line.startIndex, offsetBy: 2)
        guard idx < line.endIndex else { return false }
        let c = line[idx]
        return c != " " && c != "#"
    }

    /// True when `token` appears in the block with YAML `#` comments stripped —
    /// so an in-block doc comment that merely *mentions* a link form can never
    /// false-positive.
    static func blockLinksToken(_ block: String, _ token: String) -> Bool {
        Self.strippingYamlComments(block).contains(token)
    }

    /// Drops YAML `#` comments: a `#` starts a comment when it is the first
    /// non-blank character of the line or is preceded by whitespace. A `#`
    /// embedded in a bareword value (no preceding space) is preserved.
    static func strippingYamlComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var result = ""
                var prevWasSpace = true   // start-of-line counts as "after whitespace"
                for ch in line {
                    if ch == "#" && prevWasSpace { break }
                    result.append(ch)
                    prevWasSpace = (ch == " " || ch == "\t")
                }
                return result
            }
            .joined(separator: "\n")
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
