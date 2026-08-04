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

    /// Complementarity is a MODEL-layer invariant: `percentRemaining` is the exact
    /// complement of the clamped raw `utilization`. It is deliberately NOT asserted
    /// against `utilizationFraction`, which is a quantised DISPLAY projection —
    /// at `utilization = 12.5` the display says 13% consumed while the model says
    /// 87.5% remaining, which is two precisions, not a contradiction.
    @Test("percentRemaining is the exact complement of the raw utilization")
    func complementaryAtTheModelLayer() {
        for u in [0.0, 12.5, 87.0, 100.0] {
            #expect(u + window(u).percentRemaining == 100)
        }
        #expect(window(130).percentRemaining == 0)     // over budget → nothing left
        #expect(window(-5).percentRemaining == 100)    // below zero → nothing spent
    }

    /// #110 verify round 2 (codex): the non-finite policy has to reach
    /// `percentRemaining` too. `100 - .infinity` is `-.infinity`, which the old
    /// `max(0, ...)` clamped to 0 — leaving one window claiming "0% consumed"
    /// (from the guard) AND "0% remaining" at the same time. An unreadable value
    /// means nothing known was spent, so everything is still available.
    @Test("a non-finite utilization reads as fully remaining, matching 0% consumed")
    func nonFiniteIsFullyRemaining() {
        for u in [Double.nan, .infinity, -.infinity] {
            #expect(window(u).utilizationPercent == 0)
            #expect(window(u).percentRemaining == 100)
        }
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

    /// #110 verify round 2 (logic + regression lenses): `utilizationPercent` must
    /// round the clamped RAW percent, not a `÷100 → ×100` round-trip. The
    /// round-trip is inexact in binary64 and lands on the wrong side of an exact
    /// `.5` tie for exactly these four values, displaying one lower than the
    /// pre-#110 label did — a silent change to an in-range displayed number.
    ///
    /// The expectations are stated independently (conventional round-half-up),
    /// NOT derived from the production expression.
    @Test("exact half-percent values round up, with no floating-point round-trip drift")
    func halfPercentTiesRoundUp() {
        #expect(window(14.5).utilizationPercent == 15)
        #expect(window(28.5).utilizationPercent == 29)
        #expect(window(56.5).utilizationPercent == 57)
        #expect(window(57.5).utilizationPercent == 58)
    }

    /// #110 verify round 2 (codex + devil's advocate): the number the user reads
    /// and the colour they see must not straddle a threshold in opposite
    /// directions. Before quantising, `89.995` displayed "90% 已用" in a YELLOW
    /// row while `UsageLevel` documents red at/above 0.90.
    ///
    /// Stated as a rule over the DISPLAYED percent, independent of how the
    /// fraction is computed: ≥90 must be critical, 70..<90 warning, <70 nominal.
    @Test("the colour band always matches the percent the label displays")
    func bandMatchesDisplayedPercent() {
        for u in [0.0, 12.5, 69.4, 69.995, 70.0, 87, 89.4, 89.995, 90.0, 99.6, 100, 130, -5, .nan, .infinity] {
            let w = window(u)
            let level = UsageLevel(fraction: w.utilizationFraction)
            let expected: UsageLevel = w.utilizationPercent >= 90 ? .critical
                                     : w.utilizationPercent >= 70 ? .warning
                                     : .nominal
            #expect(level == expected, "utilization \(u) displays \(w.utilizationPercent)% but banded as \(level)")
        }
    }
}
