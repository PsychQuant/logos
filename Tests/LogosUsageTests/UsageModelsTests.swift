import Testing
import LogosUsage

/// #110: `utilizationFraction` is the 0–1 consumed fraction every usage bar
/// feeds to `UsageLevel`. It clamps at the model layer — mirroring
/// `percentRemaining`'s existing clamp — so no view has to defend against an
/// out-of-range `utilization` on its own.
@Suite("UsageWindow.utilizationFraction")
struct UsageWindowFractionTests {

    private func window(_ utilization: Double) -> UsageWindow {
        UsageWindow(id: "five_hour", label: "5 小時", utilization: utilization)
    }

    @Test("an unused window is 0")
    func empty() {
        #expect(window(0).utilizationFraction == 0)
    }

    @Test("a mid-range utilization divides by 100")
    func midRange() {
        #expect(window(87).utilizationFraction == 0.87)
    }

    @Test("a fully consumed window is 1")
    func full() {
        #expect(window(100).utilizationFraction == 1)
    }

    @Test("an over-budget utilization clamps to 1")
    func clampsHigh() {
        #expect(window(130).utilizationFraction == 1)
    }

    @Test("a negative utilization clamps to 0")
    func clampsLow() {
        #expect(window(-5).utilizationFraction == 0)
    }

    /// The two derived views of the same field stay complementary across the
    /// normal range — the guard against a future edit flipping one and not the other.
    @Test("utilizationFraction and percentRemaining stay complementary")
    func complementary() {
        let w = window(87)
        #expect(w.utilizationFraction * 100 + w.percentRemaining == 100)
    }

    /// #110 verify (devil's advocate + codex, both HIGH): `min`/`max` are NOT NaN
    /// sanitizers. Swift's `min(x, y)` is `y < x ? y : x`, and every comparison
    /// against NaN is false, so `min(1, .nan)` returns **1**, not NaN — the old
    /// `max(0, min(1, utilization / 100))` turned a non-finite reading into a FULL,
    /// CRITICAL, red bar. The pre-#110 status bar fed the raw value to
    /// `HUDProgressBar`, whose `f.isFinite ? f : 0` collapsed it to an empty green
    /// bar, so the ensemble was right that rendering changed — in the worst possible
    /// direction. The fraction must guard finiteness itself.
    @Test("a non-finite utilization collapses to 0, never to a full red bar")
    func nonFiniteCollapsesToZero() {
        #expect(window(.nan).utilizationFraction == 0)
        #expect(window(.infinity).utilizationFraction == 0)
        #expect(window(-.infinity).utilizationFraction == 0)
    }

    /// #110 verify: `UsageLevel`'s documented contract ("a non-finite input collapses
    /// to the nominal band so an empty bar never flashes red") has to hold through the
    /// path production actually uses — `UsageWindow.utilizationFraction` — not only
    /// when a test hands `UsageLevel` a bare `.nan`.
    @Test("a non-finite utilization stays in the nominal band end-to-end")
    func nonFiniteIsNominalThroughTheRealPath() {
        #expect(UsageLevel(fraction: window(.nan).utilizationFraction) == .nominal)
        #expect(UsageLevel(fraction: window(.infinity).utilizationFraction) == .nominal)
    }
}

/// #110 verify (codex, MEDIUM ×2): the label used to read the raw `utilization`
/// while the bar read the clamped fraction, so the two halves of one row could
/// disagree (`130% 已用` next to a bar pinned at full) — and `Int(Double)` traps
/// outright on a non-finite value. `utilizationPercent` is the single derived
/// display number: same clamp as the bar, and integer-convertible by construction.
@Suite("UsageWindow.utilizationPercent")
struct UsageWindowPercentTests {

    private func window(_ utilization: Double) -> UsageWindow {
        UsageWindow(id: "five_hour", label: "5 小時", utilization: utilization)
    }

    @Test("an in-range utilization round-trips to the same integer percent")
    func inRange() {
        #expect(window(0).utilizationPercent == 0)
        #expect(window(87).utilizationPercent == 87)
        #expect(window(100).utilizationPercent == 100)
    }

    @Test("an out-of-range utilization clamps the same way the bar does")
    func clamps() {
        #expect(window(130).utilizationPercent == 100)
        #expect(window(-5).utilizationPercent == 0)
    }

    @Test("a non-finite utilization yields 0 rather than trapping on Int conversion")
    func nonFinite() {
        #expect(window(.nan).utilizationPercent == 0)
        #expect(window(.infinity).utilizationPercent == 0)
    }

    /// The invariant that makes a desynced row unrepresentable: the label's number
    /// and the bar's fill are two projections of ONE clamped value.
    @Test("the label percent always agrees with the bar fraction")
    func labelAgreesWithBar() {
        for u in [0.0, 12.5, 87, 99.6, 100, 130, -5, .nan, .infinity] {
            let w = window(u)
            #expect(Double(w.utilizationPercent) == (w.utilizationFraction * 100).rounded())
        }
    }
}
