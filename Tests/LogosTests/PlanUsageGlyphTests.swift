import Testing
import Foundation
import LogosUsage
@testable import Logos

/// #93: the status-bar plan segment must render every non-loaded state distinctly instead of
/// collapsing them into a bare "—". `PlanUsageGlyph.from` is the pure mapping the view switches on;
/// these pin each `AccountUsageModel.LoadState` (and the nil / empty-windows edges) to its glyph.
@Suite("PlanUsageGlyph")
struct PlanUsageGlyphTests {

    private func window(_ id: String, _ util: Double) -> UsageWindow {
        UsageWindow(id: id, label: id, utilization: util)
    }

    @Test("no matching account row → unknown (not a bar)")
    func nilStateIsUnknown() {
        #expect(PlanUsageGlyph.from(nil) == .unknown)
    }

    @Test("idle and loading both map to loading")
    func idleAndLoading() {
        #expect(PlanUsageGlyph.from(.idle) == .loading)
        #expect(PlanUsageGlyph.from(.loading) == .loading)
    }

    @Test("loaded with windows → bars")
    func loadedWithWindowsIsBars() {
        let usage = PlanUsage(windows: [window("five_hour", 45), window("seven_day", 67)])
        #expect(PlanUsageGlyph.from(.loaded(usage, fetchedAt: Date())) == .bars)
    }

    @Test("loaded with no windows → empty, distinct from bars")
    func loadedEmptyIsEmpty() {
        #expect(PlanUsageGlyph.from(.loaded(PlanUsage(windows: []), fetchedAt: Date())) == .empty)
    }

    @Test("each terminal failure state keeps its own glyph — none collapses to a bare dash")
    func terminalStatesAreDistinct() {
        #expect(PlanUsageGlyph.from(.noCredentials) == .noCredentials)
        #expect(PlanUsageGlyph.from(.needsLogin) == .needsLogin)
        #expect(PlanUsageGlyph.from(.failed("伺服器錯誤（HTTP 500）")) == .failed)
        // The whole point of #93: needsLogin (re-loginable) is NOT the same as failed or empty.
        #expect(PlanUsageGlyph.from(.needsLogin) != PlanUsageGlyph.from(.failed("x")))
        #expect(PlanUsageGlyph.from(.needsLogin) != PlanUsageGlyph.from(.loaded(PlanUsage(windows: []), fetchedAt: Date())))
    }
}
