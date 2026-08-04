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
}
