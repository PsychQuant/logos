import Testing
@testable import Logos

/// #90: the pure colour-band classification behind the HUD progress bars.
/// `fraction` is the CONSUMED fraction (0 = empty, 1 = full) for both the
/// context-window bar and the 5-hour plan bar, so a higher fraction is always
/// worse. The bands: green below 0.70, yellow in 0.70..<0.90, red at/above 0.90.
@Suite("HUDUsageLevel")
struct HUDUsageLevelTests {

    @Test("below 70% consumed is nominal (green band)")
    func nominalBand() {
        #expect(HUDUsageLevel(fraction: 0.0) == .nominal)
        #expect(HUDUsageLevel(fraction: 0.50) == .nominal)
        #expect(HUDUsageLevel(fraction: 0.699) == .nominal)
    }

    @Test("the 70% boundary enters the warning (yellow) band")
    func warningLowerBoundary() {
        #expect(HUDUsageLevel(fraction: 0.70) == .warning)
    }

    @Test("70–90% consumed is warning (yellow band)")
    func warningBand() {
        #expect(HUDUsageLevel(fraction: 0.80) == .warning)
        #expect(HUDUsageLevel(fraction: 0.899) == .warning)
    }

    @Test("the 90% boundary enters the critical (red) band")
    func criticalLowerBoundary() {
        #expect(HUDUsageLevel(fraction: 0.90) == .critical)
    }

    @Test("above 90% consumed is critical (red band), including over-budget")
    func criticalBand() {
        #expect(HUDUsageLevel(fraction: 0.95) == .critical)
        #expect(HUDUsageLevel(fraction: 1.0) == .critical)
        #expect(HUDUsageLevel(fraction: 1.5) == .critical)
    }

    /// A fresh session has no usage: the context fraction is 0 (empty bar, green).
    /// A malformed divide (0/0 → NaN, or a non-finite input) must never colour the
    /// bar red — it collapses to the nominal band so an empty HUD reads calm, not alarming.
    @Test("non-finite fractions collapse to nominal (empty / fresh session)")
    func defensiveNonFinite() {
        #expect(HUDUsageLevel(fraction: .nan) == .nominal)
        #expect(HUDUsageLevel(fraction: .infinity) == .nominal)
        #expect(HUDUsageLevel(fraction: -.infinity) == .nominal)
    }

    @Test("a negative fraction is below the warning threshold → nominal")
    func negativeIsNominal() {
        #expect(HUDUsageLevel(fraction: -0.2) == .nominal)
    }
}
