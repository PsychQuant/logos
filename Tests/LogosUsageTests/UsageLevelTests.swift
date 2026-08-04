import Testing
import LogosUsage

/// #90 / #110: the pure colour-band classification behind every usage bar.
/// `fraction` is the CONSUMED fraction (0 = empty, 1 = full) — for the status
/// bar's context + plan bars AND (since #110) the 帳號用量 window's plan bars, so
/// a higher fraction is always worse. The bands: green below 0.70, yellow in
/// 0.70..<0.90, red at/above 0.90.
///
/// Moved here from `Tests/LogosTests/HUDUsageLevelTests.swift` in #110: the type
/// lives in `LogosUsage` now (the app module can import the library, not the
/// reverse), so the 帳號用量 window's `UsageBar` can share the same bands instead
/// of carrying its own inverted ones. Assertions are unchanged — the thresholds
/// and their consumed-fraction semantics did not move.
@Suite("UsageLevel")
struct UsageLevelTests {

    @Test("below 70% consumed is nominal (green band)")
    func nominalBand() {
        #expect(UsageLevel(fraction: 0.0) == .nominal)
        #expect(UsageLevel(fraction: 0.50) == .nominal)
        #expect(UsageLevel(fraction: 0.699) == .nominal)
    }

    @Test("the 70% boundary enters the warning (yellow) band")
    func warningLowerBoundary() {
        #expect(UsageLevel(fraction: 0.70) == .warning)
    }

    @Test("70–90% consumed is warning (yellow band)")
    func warningBand() {
        #expect(UsageLevel(fraction: 0.80) == .warning)
        #expect(UsageLevel(fraction: 0.899) == .warning)
    }

    @Test("the 90% boundary enters the critical (red) band")
    func criticalLowerBoundary() {
        #expect(UsageLevel(fraction: 0.90) == .critical)
    }

    @Test("above 90% consumed is critical (red band), including over-budget")
    func criticalBand() {
        #expect(UsageLevel(fraction: 0.95) == .critical)
        #expect(UsageLevel(fraction: 1.0) == .critical)
        #expect(UsageLevel(fraction: 1.5) == .critical)
    }

    /// A fresh session has no usage: the context fraction is 0 (empty bar, green).
    /// A malformed divide (0/0 → NaN, or a non-finite input) must never colour the
    /// bar red — it collapses to the nominal band so an empty HUD reads calm, not alarming.
    @Test("non-finite fractions collapse to nominal (empty / fresh session)")
    func defensiveNonFinite() {
        #expect(UsageLevel(fraction: .nan) == .nominal)
        #expect(UsageLevel(fraction: .infinity) == .nominal)
        #expect(UsageLevel(fraction: -.infinity) == .nominal)
    }

    @Test("a negative fraction is below the warning threshold → nominal")
    func negativeIsNominal() {
        #expect(UsageLevel(fraction: -0.2) == .nominal)
    }
}
