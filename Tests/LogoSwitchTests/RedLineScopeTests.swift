import Foundation
import Testing

/// Package-wide red-line scope guard (merge-multistats-into-logos, task 4.1/4.2).
///
/// The original `RedLineAuditTests` (untouched) keeps LogoSwitch structurally
/// incapable of credential access. With the MultiStats merge, the isolation
/// story widens from "this repo never touches credentials" to "credential
/// READS exist in exactly one audited, structurally read-only target" — and
/// that is only durable as tests:
///
/// - **Scope** ("Security framework usage is confined to the audited usage
///   target"): the same forbidden-token scan applies to `Sources/LogosAccounts`
///   ("The registry target is structurally credential-free") and
///   `Sources/Logos` (the app must not grow ad-hoc keychain code); a
///   package-wide scan proves `import Security` appears only under
///   `Sources/LogosUsage`.
/// - **Read-only** ("Keychain writes are structurally forbidden
///   package-wide"): no `SecItemAdd`/`SecItemUpdate`/`SecItemDelete` token in
///   compiled code of ANY target — including LogosUsage itself, whose only
///   permitted call shape is `SecItemCopyMatching`.
@Suite struct RedLineScopeTests {

    /// Same attack-form list the LogoSwitch red line uses.
    static let forbidden = [
        "import Security",
        "SecItem",
        "find-generic-password",
        "add-generic-password",
        "/usr/bin/security",
    ]

    /// Keychain WRITE forms — forbidden everywhere, including LogosUsage.
    static let writeTokens = ["SecItemAdd", "SecItemUpdate", "SecItemDelete"]

    /// Targets that must remain structurally credential-free.
    static let credentialFreeTargets = ["Sources/LogosAccounts", "Sources/Logos", "Sources/MultiStats"]

    /// The single target permitted to import Security.
    static let auditedUsageTarget = "Sources/LogosUsage"

    @Test func credentialFreeTargetsContainNoCredentialAccess() throws {
        for target in Self.credentialFreeTargets {
            let dir = Self.repoRoot().appendingPathComponent(target, isDirectory: true)
            let files = try Self.swiftFiles(in: dir)
            #expect(!files.isEmpty, "expected at least one .swift file under \(dir.path)")
            for file in files {
                let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
                for token in Self.forbidden {
                    #expect(
                        !code.contains(token),
                        "RED-LINE VIOLATION: \(target)/\(file.lastPathComponent) contains '\(token)' in code (not a comment). Credential access belongs only in LogosUsage."
                    )
                }
            }
        }
    }

    @Test func securityImportAppearsOnlyUnderLogosUsage() throws {
        let sourcesRoot = Self.repoRoot().appendingPathComponent("Sources", isDirectory: true)
        let usagePrefix = Self.repoRoot().appendingPathComponent(Self.auditedUsageTarget, isDirectory: true).path
        var importersOutsideUsage: [String] = []
        var usageImportsSecurity = false

        for file in try Self.swiftFiles(in: sourcesRoot) {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            guard code.contains("import Security") else { continue }
            if file.path.hasPrefix(usagePrefix) {
                usageImportsSecurity = true
            } else {
                importersOutsideUsage.append(file.path)
            }
        }

        #expect(
            importersOutsideUsage.isEmpty,
            "RED-LINE VIOLATION: Security imported outside \(Self.auditedUsageTarget): \(importersOutsideUsage)"
        )
        // The fence is meaningful only while the audited target actually holds
        // the keychain read — if this flips, the scan is scanning the wrong place.
        #expect(usageImportsSecurity, "expected \(Self.auditedUsageTarget) to be the live Security importer")
    }

    @Test func keychainWritesAreForbiddenPackageWide() throws {
        let sourcesRoot = Self.repoRoot().appendingPathComponent("Sources", isDirectory: true)
        for file in try Self.swiftFiles(in: sourcesRoot) {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for token in Self.writeTokens {
                #expect(
                    !code.contains(token),
                    "RED-LINE VIOLATION: \(file.lastPathComponent) contains '\(token)' — the package is structurally read-only against the Keychain."
                )
            }
        }
    }

    // MARK: - helpers (same shapes as RedLineAuditTests)

    /// `<repo>`, derived from this test file's location:
    /// …/Tests/LogoSwitchTests/RedLineScopeTests.swift → up 3 → repo root.
    static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // LogoSwitchTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }

    static func swiftFiles(in dir: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Removes `/* … */` block comments and full-line `//` / `///` comments.
    /// String literals are preserved, so a `/usr/bin/security` literal or a
    /// `find-generic-password` argument is still caught.
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
