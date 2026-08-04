import Foundation

/// One rolling plan-usage window reported by Claude Code's usage endpoint.
///
/// The two windows the `/usage` panel surfaces are the five-hour "session"
/// budget and the seven-day "weekly" budget. `utilization` is a percentage
/// (0–100) of the window consumed — confirmed empirically against the live
/// endpoint, where it matches the `limits[].percent` field.
public struct UsageWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    /// Percent of the window consumed, 0–100.
    public let utilization: Double
    public let resetsAt: Date?

    public init(
        id: String,
        label: String,
        utilization: Double,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// The integer percent every usage row displays — the **single quantised
    /// value** the label, the bar fill and the colour band are all derived from
    /// (#110). Clamped to 0–100; a non-finite reading is 0.
    ///
    /// Two properties of how this is computed are load-bearing:
    ///
    /// 1. The `isFinite` guard comes FIRST, because `min` / `max` do **not**
    ///    sanitize NaN. Swift's `min(x, y)` is `y < x ? y : x`, and every
    ///    comparison against NaN is false, so `min(1, .nan)` returns `1` — a bare
    ///    `max(0, min(1, utilization / 100))` renders a non-finite reading as a
    ///    FULL, CRITICAL, red bar, and `Int(_: Double)` traps on it outright
    ///    (#110 verify round 1, devil's advocate + codex, both HIGH).
    /// 2. It rounds the **clamped raw percent**, not a `÷100 → ×100` round-trip.
    ///    That round-trip is not exact in binary64 and lands ~1 ULP on the wrong
    ///    side of an exact `.5` tie for `14.5`, `28.5`, `56.5`, `57.5`, each of
    ///    which would display one lower than a direct rounding (#110 verify
    ///    round 2, logic + regression lenses).
    public var utilizationPercent: Int {
        guard utilization.isFinite else { return 0 }
        return Int(max(0, min(100, utilization)).rounded())
    }

    /// The consumed fraction, 0–1, that drives the bar fill and the `UsageLevel`
    /// colour band — a **display projection**, derived from `utilizationPercent`
    /// so a row's number and its colour cannot straddle a threshold in opposite
    /// directions.
    ///
    /// Quantising here is deliberate. Reading the band off the unrounded fraction
    /// while the label rounded meant `utilization = 89.995` displayed "90% 已用"
    /// in a *yellow* row, contradicting this type's own documented "red at/above
    /// 0.90" (#110 verify round 2, codex + devil's advocate). The cost is that the
    /// fill quantises to 1% steps — sub-pixel at these bar widths.
    ///
    /// Being quantised, this is NOT the exact complement of `percentRemaining`:
    /// at `utilization = 12.5` it reads 13% while `percentRemaining` reads 87.5%.
    /// That is the display layer and the model layer answering at different
    /// precisions, not a contradiction — the exact complement holds between
    /// `percentRemaining` and the raw `utilization`.
    public var utilizationFraction: Double { Double(utilizationPercent) / 100 }

    /// Percent of the window still available, clamped to 0–100.
    ///
    /// #110: model-level API only. No view reads this — every usage surface
    /// renders the CONSUMED side (`utilizationPercent` / `utilizationFraction`)
    /// so the status bar and the 帳號用量 window agree on which direction "full"
    /// means. It stays complementary to the consumed side on every input,
    /// including non-finite: an unreadable value is 0% consumed, so it is 100%
    /// remaining, not the 0% that `100 - .infinity` would otherwise clamp to
    /// (#110 verify round 2, codex).
    public var percentRemaining: Double {
        guard utilization.isFinite else { return 100 }
        return max(0, min(100, 100 - utilization))
    }
}

/// Aggregated plan usage for a single account. An empty `windows` array is a
/// valid, non-error state (endpoint responded but exposed no known windows) —
/// distinct from a failed fetch, which surfaces as a thrown `UsageError`.
public struct PlanUsage: Equatable, Sendable {
    public let windows: [UsageWindow]
    public init(windows: [UsageWindow]) { self.windows = windows }
}
