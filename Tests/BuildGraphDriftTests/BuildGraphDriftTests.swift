import Foundation
import Testing
import Yams

/// Build-graph drift guard (#65).
///
/// The first-party module graph is described twice. `Package.swift` drives
/// `swift build` / `swift test`; `project.yml` (XcodeGen) drives the Track B
/// `xcodebuild` path — the app-hosted renderer tests, snapshot tests, and
/// XCUITest. Every `Package.swift` LIBRARY target the app graph imports must be
/// re-declared as an XcodeGen target in `project.yml`, or `import <Module>` fails
/// under `xcodebuild` and *all* of Track B fails to compile — silently, because a
/// plain `swift test` (which reads only `Package.swift`) stays green. That drift
/// has broken Track B twice: #39 (`LogoSwitch`) and #60 (`LogosAccounts` +
/// `LogosUsage`), each caught only when someone happened to run the rare hosted
/// build.
///
/// This suite makes the drift fail loud in the `swift test` hard gate: it parses
/// the library targets out of `Package.swift`, the `targets:` keys out of
/// `project.yml`, and asserts the former is a subset of the latter. The parse
/// helpers are pure (`String` in, `[String]` out), so the RED case is proved on a
/// synthetic missing-target pair without mutating the real files.
@Suite struct BuildGraphDriftTests {

    /// The checked-in graph is consistent: every `Package.swift` library target is
    /// mirrored in `project.yml`. GREEN today —
    /// `{LogosAccounts, LogosUsage, LogoSwitch}` ⊆ project.yml targets.
    @Test func packageLibrariesAreAllMirroredInProjectYml() throws {
        let packageSwift = try String(contentsOf: Self.packageSwiftURL(), encoding: .utf8)
        let projectYml = try String(contentsOf: Self.projectYmlURL(), encoding: .utf8)

        let libraries = Self.packageLibraryTargets(in: packageSwift)
        let projectTargets = try Self.projectYmlTargetKeys(in: projectYml)

        // Extraction sanity: found the three known libraries and NOT the `Logos`
        // executable or any test target — keeping an executable (deliberately absent
        // from project.yml) from being a false positive. (The MultiStats executable
        // that used to sit alongside Logos here was retired in #92.)
        #expect(
            Set(libraries) == ["LogosAccounts", "LogosUsage", "LogoSwitch"],
            "Package.swift library extraction drifted: got \(libraries.sorted())"
        )
        #expect(!libraries.contains("Logos"), ".executableTarget(Logos) must not be read as a library")

        let missing = Self.missingTargets(libraries: libraries, projectTargets: projectTargets)
        #expect(
            missing.isEmpty,
            """
            project.yml is missing Package.swift library target(s): \(missing.sorted()). \
            Add a matching XcodeGen target (mirror the LogoSwitch framework recipe at project.yml), \
            or Track B (hosted / snapshot / UI tests) will silently fail to compile — \
            'import \(missing.first ?? "<Module>")' won't resolve under xcodebuild (#39 / #60 / #65).
            """
        )
    }

    /// RED proof on the pure comparison logic, run against a synthetic pair so the
    /// real files stay untouched: a library present in `Package.swift` but absent
    /// from `project.yml` must be flagged by name, and `.executableTarget` /
    /// `.testTarget` must be skipped (the executable / test-target false-positive boundary).
    @Test func syntheticMissingTargetIsDetectedAndExecutablesAreExcluded() throws {
        let syntheticPackage = """
        let package = Package(
            targets: [
                .target(name: "Alpha"),
                .target(name: "Beta", dependencies: ["Alpha"]),
                .executableTarget(name: "GammaExe", dependencies: ["Alpha"]),
                .testTarget(name: "AlphaTests", dependencies: ["Alpha"])
            ]
        )
        """
        let libraries = Self.packageLibraryTargets(in: syntheticPackage)
        #expect(
            Set(libraries) == ["Alpha", "Beta"],
            "extractor must read only lowercase .target( libraries; got \(libraries.sorted())"
        )
        #expect(!libraries.contains("GammaExe"), ".executableTarget must be excluded")
        #expect(!libraries.contains("AlphaTests"), ".testTarget must be excluded")

        // project.yml mirrors Alpha but NOT Beta -> Beta is drift.
        let syntheticYml = """
        targets:
          Alpha:
            type: framework
          SomeApp:
            type: application
        """
        let projectTargets = try Self.projectYmlTargetKeys(in: syntheticYml)
        #expect(Set(projectTargets) == ["Alpha", "SomeApp"])

        let missing = Self.missingTargets(libraries: libraries, projectTargets: projectTargets)
        #expect(
            missing == ["Beta"],
            "drift guard must flag the un-mirrored library 'Beta'; got \(missing.sorted())"
        )
    }

    /// #65 round-2: the widened `\.target\s*\(\s*name\s*:\s*"` extractor tolerates the
    /// whitespace/newline forms the stricter `\.target\(\s*name:` missed — a
    /// space-before-paren `.target (name: "X")` and a multi-line
    /// `.target(\n  name : "X"\n)` — and full-line `//` comments are stripped so a
    /// commented-out target is not a phantom library. Under the pre-fix regex both
    /// `Spaced` and `MultiLine` went unread, so a real un-mirrored library declared
    /// in either form would silently pass the drift guard (Track B breaks later).
    @Test func extractorToleratesWhitespaceFormsAndSkipsCommentedTargets() throws {
        let syntheticPackage = """
        let package = Package(
            targets: [
                .target(name: "Tight"),
                .target (name: "Spaced"),
                .target(
                    name : "MultiLine"
                ),
                // .target(name: "CommentedOut")
                .executableTarget(name: "AppExe"),
                .testTarget(name: "TightTests")
            ]
        )
        """
        let libraries = Self.packageLibraryTargets(in: syntheticPackage)
        #expect(
            Set(libraries) == ["Tight", "Spaced", "MultiLine"],
            "widened extractor must catch spaced + multi-line .target forms and skip comments; got \(libraries.sorted())"
        )
        #expect(!libraries.contains("CommentedOut"), "a full-line // commented .target must not be read as a library")
        #expect(!libraries.contains("AppExe"), ".executableTarget must still be excluded")
        #expect(!libraries.contains("TightTests"), ".testTarget must still be excluded")
    }

    // MARK: - pure extraction helpers

    /// Library targets declared in `Package.swift` — the lowercase `.target(name:)`
    /// form only. `\.target\s*\(\s*name\s*:\s*"` matches a literal `.target(` and is
    /// whitespace/newline-tolerant, so `.target (name: "X")` and a multi-line
    /// `.target(\n  name : "X"\n)` are both caught (`\s` spans newlines in ICU).
    /// `.executableTarget(` and `.testTarget(` use a capital-T `Target(` with no
    /// preceding dot, so neither matches `\.target` (excludes `Logos` and every
    /// test target). Full-line `//` comments are stripped first (house
    /// idiom, mirrors RedLineAuditTests.strippingComments) so a commented-out
    /// `.target(name: "X")` is not read as a live library.
    static func packageLibraryTargets(in packageSwift: String) -> [String] {
        let code = packageSwift
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let pattern = #"\.target\s*\(\s*name\s*:\s*"([^"]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..., in: code)
        return re.matches(in: code, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: code) else { return nil }
            return String(code[r])
        }
    }

    /// The `targets:` mapping keys in `project.yml`, via a structural `Yams`
    /// decode — robust against the indentation-grep fragility that would also
    /// match `packages:` keys or the `schemes:` block.
    static func projectYmlTargetKeys(in yaml: String) throws -> [String] {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any],
              let targets = root["targets"] as? [String: Any] else {
            return []
        }
        return Array(targets.keys)
    }

    /// Package libraries with no matching key under `project.yml`'s `targets:` —
    /// the drift set. Empty means the two sources of truth agree.
    static func missingTargets(libraries: [String], projectTargets: [String]) -> [String] {
        let present = Set(projectTargets)
        return libraries.filter { !present.contains($0) }
    }

    // MARK: - file location (RedLineAuditTests model: up 3 -> repo root)

    static func packageSwiftURL(file: StaticString = #filePath) -> URL {
        repoRoot(file: file).appendingPathComponent("Package.swift", isDirectory: false)
    }

    static func projectYmlURL(file: StaticString = #filePath) -> URL {
        repoRoot(file: file).appendingPathComponent("project.yml", isDirectory: false)
    }

    /// `<repo>` derived from this test file's location:
    /// …/Tests/BuildGraphDriftTests/BuildGraphDriftTests.swift -> up 3 -> repo root.
    static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // BuildGraphDriftTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }
}
