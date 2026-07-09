import Testing
import Foundation

/// Guards PsychQuant/logos#75: the announce-at-setter discipline in
/// `AccountSwitcherSheet.swift`. The four `@State` error slots
/// (`addError`/`renameError`/`deleteError`/`systemDefaultError`) must only ever be
/// set to a non-`nil` value through one of the four `set*Error` helpers, which
/// route the VoiceOver announcement through the `announce` seam (#75 option 3).
/// Before #75 this discipline was comment-only — a future direct
/// `renameError = "…"` would compile and silently skip the announcement, leaving a
/// failure caption inaudible (the #71 round-2 regression). This source-scan freezes
/// the invariant: a bypass, a setter that stops announcing, or a seam whose default
/// no longer posts each trips a RED here.
///
/// Same house idiom as `LoggingHygieneTests` / `RedLineAuditTests`: derive the repo
/// root from `#filePath`, scan the one source file, collect offenders, and prove the
/// matcher isn't vacuous with synthetic violating snippets (the RED proof) before
/// asserting GREEN on the real file.
///
/// Known limitation (shared with `LoggingHygieneTests`): only *full-line* `//`
/// comments are stripped, so a hypothetical inline `code // renameError = "x"` could
/// false-positive. No such line exists today; prefer rewording over weakening the
/// guard if one appears.
@Suite("AnnounceAtSetterGuard")
struct AnnounceAtSetterGuardTests {

    // MARK: - Real-file guards (GREEN today)

    @Test("no non-nil error-slot assignment bypasses the set*Error helpers")
    func realFileNoBypass() throws {
        let offenders = Self.bypassOffenders(in: try Self.sheetSource())
        #expect(
            offenders.isEmpty,
            """
            direct non-nil write to a @State error slot OUTSIDE a set*Error helper — \
            it would skip the VoiceOver announcement (#75). Route it through the setter:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("every set*Error helper routes through the announce seam")
    func realFileSettersAnnounce() throws {
        let offenders = Self.settersMissingAnnouncer(in: try Self.sheetSource())
        #expect(
            offenders.isEmpty,
            "set*Error helper(s) no longer call announce(message) — the caption would go silent (#75): \(offenders.joined(separator: ", "))"
        )
    }

    @Test("the announce seam defaults to the real VoiceOver post")
    func realFileDefaultPosts() throws {
        let source = try Self.sheetSource()
        #expect(
            source.contains("AccessibilityNotification.Announcement($0).post()"),
            "the announce seam's default no longer performs the real AccessibilityNotification.Announcement(...).post() — VoiceOver would go silent even with every setter routed (#75)"
        )
    }

    // MARK: - Detector sanity (RED proof: the matcher flags synthetic violations)

    @Test("matcher flags a literal-string bypass outside a helper")
    func detectorFlagsLiteralBypass() {
        let synthetic = """
        struct S {
            func commitRename() {
                renameError = "boom"
            }
        }
        """
        #expect(!Self.bypassOffenders(in: synthetic).isEmpty)
    }

    @Test("matcher flags a variable-form bypass (stronger than literal-only)")
    func detectorFlagsVariableBypass() {
        let synthetic = """
        struct S {
            func f(_ m: String) {
                deleteError = m
            }
        }
        """
        #expect(!Self.bypassOffenders(in: synthetic).isEmpty)
    }

    @Test("matcher allows nil clears and an in-helper = message assignment")
    func detectorAllowsLegitimate() {
        let synthetic = """
        struct S {
            func selectAccount() {
                deleteError = nil
                systemDefaultError = nil
            }
            func setRenameError(_ message: String) {
                renameError = message
                announce(message)
            }
        }
        """
        #expect(Self.bypassOffenders(in: synthetic).isEmpty)
    }

    @Test("matcher flags a set*Error helper that skips the announce seam")
    func detectorFlagsMissingAnnouncer() {
        let synthetic = """
        struct S {
            func setRenameError(_ message: String) {
                renameError = message
            }
        }
        """
        #expect(!Self.settersMissingAnnouncer(in: synthetic).isEmpty)
    }

    // MARK: - Matcher

    /// The four `@State` error slots the discipline governs.
    static let slots = ["addError", "renameError", "deleteError", "systemDefaultError"]

    /// Every non-`nil` assignment to one of the four slots that lands OUTSIDE a
    /// `set*Error` helper body. A `= nil` clear is legitimate anywhere; a non-`nil`
    /// write (literal OR variable) is a bypass unless it is the helper's own
    /// `slot = message` line.
    static func bypassOffenders(in source: String) -> [String] {
        let lines = commentStrippedLines(source)
        let setterIndices = Set(setterBodies(lines).flatMap(\.indices))
        // `=(?!=)` excludes `==`; group 2 captures the RHS up to a `;` (multiple
        // assignments per line, e.g. `deleteError = nil; renameError = nil`).
        let assignRe = try! NSRegularExpression(
            pattern: #"\b(addError|renameError|deleteError|systemDefaultError)\s*=(?!=)\s*([^;\n]*)"#
        )
        let nilRe = try! NSRegularExpression(pattern: #"^nil($|\b)"#)

        var offenders: [String] = []
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            for m in assignRe.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let slot = ns.substring(with: m.range(at: 1))
                let rhs = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let rhsNS = rhs as NSString
                let isNilClear = nilRe.firstMatch(in: rhs, range: NSRange(location: 0, length: rhsNS.length)) != nil
                if isNilClear { continue }
                if !setterIndices.contains(i) {
                    offenders.append("\(i + 1): [\(slot)] \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return offenders
    }

    /// The names of any `set*Error` helper whose body does NOT call `announce(` —
    /// i.e. a setter that mutates its slot without announcing.
    static func settersMissingAnnouncer(in source: String) -> [String] {
        let lines = commentStrippedLines(source)
        return setterBodies(lines).compactMap { body in
            let text = body.indices.map { lines[$0] }.joined(separator: "\n")
            return text.contains("announce(") ? nil : body.name
        }
    }

    // MARK: - Helpers

    private struct SetterBody { let name: String; let indices: [Int] }

    /// The line ranges (0-based indices) of each `set*Error` helper, from its
    /// signature line through the line whose `}` returns brace depth to 0. Brace
    /// counting assumes no `{`/`}` inside string literals or inline comments within
    /// these bodies — true for the three-line setters this guards.
    private static func setterBodies(_ lines: [String]) -> [SetterBody] {
        let sigRe = try! NSRegularExpression(
            pattern: #"func\s+(set(?:Add|Rename|Delete|SystemDefault)Error)\b"#
        )
        var result: [SetterBody] = []
        var i = 0
        while i < lines.count {
            let ns = lines[i] as NSString
            guard let m = sigRe.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)) else {
                i += 1
                continue
            }
            let name = ns.substring(with: m.range(at: 1))
            var indices: [Int] = []
            var depth = 0
            var opened = false
            var j = i
            while j < lines.count {
                indices.append(j)
                for ch in lines[j] {
                    if ch == "{" { depth += 1; opened = true }
                    else if ch == "}" { depth -= 1 }
                }
                if opened && depth <= 0 { break }
                j += 1
            }
            result.append(SetterBody(name: name, indices: indices))
            i = j + 1
        }
        return result
    }

    /// Full-line `//` comments blanked to "" (indices preserved so reported line
    /// numbers stay accurate). Matches `LoggingHygieneTests`' full-line-only strip.
    private static func commentStrippedLines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            return line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : line
        }
    }

    private static func sheetSource() throws -> String {
        try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/Logos/Views/AccountSwitcher/AccountSwitcherSheet.swift"
            ),
            encoding: .utf8
        )
    }

    /// `#filePath` = <repo>/Tests/LogosTests/AnnounceAtSetterGuardTests.swift
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LogosTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
    }
}
