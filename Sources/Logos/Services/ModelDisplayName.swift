import Foundation

/// #116: render a claude model id the way Claude Code itself does — `Opus 5 (1M)` rather
/// than the raw `claude-opus-5[1m]`.
///
/// **A parser, not a lookup table.** Point releases arrive constantly; a table falls through
/// to the raw id for every model shipped after its last edit, which is precisely the
/// staleness that left `baseWindow(forModel:)` returning a flat 200k for a whole model
/// generation (#113). Parsing the id's own shape ages better than enumerating it.
enum ModelDisplayName {

    /// A component that is 8+ digits is a dated snapshot (`20251001`), not a version
    /// component — `claude-haiku-4-5-20251001` is Haiku 4.5, not Haiku 4.5.20251001.
    private static func isDateStamp(_ component: Substring) -> Bool {
        component.count >= 8 && component.allSatisfy(\.isNumber)
    }

    /// Display name for a model id, optionally annotated with its context window.
    ///
    /// - Parameter contextWindow: when it is the 1M window, the name carries `(1M)` — the
    ///   base window is the unremarkable case and stays unannotated. Passing 0 (unknown)
    ///   annotates nothing rather than guessing.
    /// - Returns: `nil` only for a nil/empty id, so the caller can hide the segment instead
    ///   of rendering an empty chip.
    static func of(_ modelID: String?, contextWindow: Int = 0) -> String? {
        guard let modelID, !modelID.isEmpty else { return nil }
        let name = family(of: modelID) ?? modelID
        return contextWindow >= 1_000_000 ? "\(name) (1M)" : name
    }

    /// `claude-opus-4-8[1m]` → `Opus 4.8`. Returns nil when the id does not have the shape
    /// this parser understands, so the caller can fall back to showing the id verbatim —
    /// an unfamiliar name is better than a confidently wrong one.
    private static func family(of modelID: String) -> String? {
        // The `[1m]` / `[1M]` suffix is a context-beta SELECTOR, not part of the family id
        // (#113). The window it selects is reported separately, from the real signal.
        let base = modelID.split(separator: "[", maxSplits: 1).first.map(String.init) ?? modelID

        var parts = base.split(separator: "-")
        guard parts.first == "claude" else { return nil }
        parts.removeFirst()

        guard let familyName = parts.first, familyName.allSatisfy(\.isLetter) else { return nil }
        parts.removeFirst()

        let version = parts
            .filter { !isDateStamp($0) }
            .filter { $0.allSatisfy(\.isNumber) }
            .joined(separator: ".")

        let capitalized = familyName.prefix(1).uppercased() + familyName.dropFirst()
        return version.isEmpty ? capitalized : "\(capitalized) \(version)"
    }
}
