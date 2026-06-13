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

    // MARK: - helpers

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
