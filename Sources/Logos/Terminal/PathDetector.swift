import Foundation

/// F-Task 10: extract path-like substrings from terminal output. Used by
/// future cmd+shift+o flow to open Claude-mentioned files in viewer.
enum PathDetector {

    /// Common path patterns:
    ///   src/Foo.swift
    ///   src/Foo.swift:42
    ///   src/Foo.swift:42:30
    ///   /Users/x/project/foo.swift
    ///   ~/project/foo.swift
    static let regex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:[~/]?[\w.-]+/)*[\w.-]+\.\w+(?::\d+(?::\d+)?)?"#
    )

    /// Extract candidate paths from text. Resolves relative against workspaceRoot.
    static func paths(in text: String, workspaceRoot: String?) -> [String] {
        guard let regex = regex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { m -> String? in
            guard let r = Range(m.range, in: text) else { return nil }
            var candidate = String(text[r])
            // Strip :line:col suffixes
            if let colonIdx = candidate.firstIndex(of: ":") {
                candidate = String(candidate[..<colonIdx])
            }
            if candidate.hasPrefix("/") {
                return candidate
            }
            if candidate.hasPrefix("~") {
                return (candidate as NSString).expandingTildeInPath
            }
            if let root = workspaceRoot {
                return "\(root)/\(candidate)"
            }
            return nil
        }
    }
}
