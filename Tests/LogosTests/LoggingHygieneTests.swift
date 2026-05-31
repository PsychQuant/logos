import Testing
import Foundation

/// Guards PsychQuant/logos#22: all diagnostic logging in `Sources/Logos` goes
/// through `os.Logger` (via the `Log` factory), never `NSLog` / `print`.
/// `print`'s stdout vanishes for a GUI app; `NSLog` has no subsystem/category so
/// `log stream` predicates can't filter it. This source-scan keeps the invariant
/// from regressing.
@Suite("LoggingHygiene")
struct LoggingHygieneTests {

    @Test("no diagnostic NSLog or print in Sources/Logos (use Log.<category> os.Logger)")
    func noNSLogOrStrayPrint() throws {
        let sourcesDir = Self.repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Logos")

        guard let enumerator = FileManager.default.enumerator(
            at: sourcesDir, includingPropertiesForKeys: nil
        ) else {
            Issue.record("could not enumerate \(sourcesDir.path)")
            return
        }

        // `print(` not preceded by an identifier char or `.` (avoids matching
        // `debugPrint(`, `foo.print(`, `_printChanges(`).
        let printPattern = #"(^|[^A-Za-z0-9_.])print\("#
        var offenders: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (idx, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let hasNSLog = line.contains("NSLog(")
                let hasPrint = line.range(of: printPattern, options: .regularExpression) != nil
                if hasNSLog || hasPrint {
                    offenders.append("\(url.lastPathComponent):\(idx + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            "diagnostic NSLog/print found — use Log.<category> (os.Logger) instead:\n\(offenders.joined(separator: "\n"))"
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
