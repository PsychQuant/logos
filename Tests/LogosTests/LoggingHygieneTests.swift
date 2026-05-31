import Testing
import Foundation

/// Guards PsychQuant/logos#22: all diagnostic logging in `Sources/Logos` goes
/// through `os.Logger` (via the `Log` factory), never `NSLog` / `print`.
/// `print`'s stdout vanishes for a GUI app; `NSLog` has no subsystem/category so
/// `log stream` predicates can't filter it. This source-scan keeps the invariant
/// from regressing.
@Suite("LoggingHygiene")
struct LoggingHygieneTests {

    @Test("no diagnostic NSLog/print/os_log/debugPrint in Sources/Logos (use Log.<category> os.Logger)")
    func noDiagnosticLoggingEscapeHatches() throws {
        let sourcesDir = Self.repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Logos")

        guard let enumerator = FileManager.default.enumerator(
            at: sourcesDir, includingPropertiesForKeys: nil
        ) else {
            Issue.record("could not enumerate \(sourcesDir.path)")
            return
        }

        // Diagnostic-logging escape hatches to forbid. The bare `print(` regex
        // excludes a leading identifier char or `.` so method calls (`foo.print(`,
        // `_printChanges(`) don't false-positive — but that same exclusion lets the
        // fully-qualified free function `Swift.print(` slip through, so it (plus the
        // `os_log(` C API and `debugPrint(`, which the lowercase-`print(` regex
        // never matches) get explicit literal checks. PsychQuant/logos#22 verify
        // (Devil's Advocate) proved `Swift.print(` evaded the original guard.
        //
        // Known limitation: the full-line `//` skip handles only leading-comment
        // lines, not trailing inline comments or string literals — a benign
        // `// print(` could false-positive. No such line exists in Sources/Logos
        // today; if one appears, prefer rewording over weakening this guard.
        let printRegex = #"(^|[^A-Za-z0-9_.])print\("#
        let literalForbidden = ["NSLog(", "os_log(", "debugPrint(", "Swift.print("]
        var offenders: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (idx, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let hit: String? = literalForbidden.first(where: { line.contains($0) })
                    ?? (line.range(of: printRegex, options: .regularExpression) != nil ? "print(" : nil)
                if let hit {
                    offenders.append("\(url.lastPathComponent):\(idx + 1): [\(hit)] \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            "diagnostic NSLog/print/os_log/debugPrint found — use Log.<category> (os.Logger) instead:\n\(offenders.joined(separator: "\n"))"
        )
    }

    /// `#filePath` = <repo>/Tests/LogosTests/LoggingHygieneTests.swift
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LogosTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
    }
}
