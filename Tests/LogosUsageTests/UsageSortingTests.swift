import Testing
import Foundation
@testable import LogosUsage

/// #112: 帳號用量's sort control.
///
/// The user's 2026-08-04 ruling picked **runway** — remaining quota ÷ hours until it
/// resets — over the two simpler candidates, because it is the only one that answers
/// "which account is about to leave me stuck". The issue's own words: 快重置但還剩 90%
/// 並不緊迫；剩 5% 且還要等三天才緊迫.
///
/// Every test injects `now`. Nothing here may read the clock: a sort whose result
/// depends on wall-time is neither testable nor stable on screen (#112 Risk 1).
@Suite("UsageSorting.runway")
@MainActor
struct UsageRunwayTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ id: String, used: Double, resetsInHours: Double?) -> UsageWindow {
        UsageWindow(
            id: id,
            label: id,
            utilization: used,
            resetsAt: resetsInHours.map { now.addingTimeInterval($0 * 3600) })
    }

    /// The ruling's own worked example. All three candidate algorithms order these three
    /// accounts differently, which is why it needed a ruling at all — runway gives A → C → B.
    @Test("the ruling's worked example orders A → C → B")
    func rulingExample() {
        let a = UsageSorting.weeklyRunway(in: PlanUsage(windows: [window("seven_day", used: 92, resetsInHours: 72)]), now: now)
        let b = UsageSorting.weeklyRunway(in: PlanUsage(windows: [window("seven_day", used: 20, resetsInHours: 4)]), now: now)
        let c = UsageSorting.weeklyRunway(in: PlanUsage(windows: [window("seven_day", used: 99, resetsInHours: 5)]), now: now)

        #expect(a != nil && b != nil && c != nil)
        #expect(a! < c!, "A (8% over 3 days) must be more urgent than C (1% over 5 hours)")
        #expect(c! < b!, "C must be more urgent than B (80% over 4 hours)")
    }

    /// The 5-hour window is NOT a weekly budget and must not steer a weekly sort.
    @Test("only weekly windows count — the 5-hour session window is ignored")
    func fiveHourIgnored() {
        let usage = PlanUsage(windows: [window("five_hour", used: 99, resetsInHours: 1)])
        #expect(UsageSorting.weeklyRunway(in: usage, now: now) == nil)
    }

    /// The ruling: take the account's MOST urgent weekly window, because what blocks you is
    /// ANY quota running out — a per-model weekly can strand you while the all-models one
    /// still looks healthy.
    @Test("with several weekly windows the most urgent one wins")
    func mostUrgentWeeklyWins() {
        let usage = PlanUsage(windows: [
            window("seven_day", used: 30, resetsInHours: 10),            // runway 7.0
            window("weekly_scoped:Opus", used: 98, resetsInHours: 10),   // runway 0.2  ← this one
            window("weekly_scoped:Haiku", used: 10, resetsInHours: 10),  // runway 9.0
        ])
        let r = UsageSorting.weeklyRunway(in: usage, now: now)
        #expect(r != nil)
        #expect(abs(r! - 0.2) < 0.0001, "expected the scoped Opus window to drive the order, got \(r!)")
    }

    @Test("an exhausted window with a long wait is maximally urgent")
    func exhaustedIsMostUrgent() {
        let usage = PlanUsage(windows: [window("seven_day", used: 100, resetsInHours: 72)])
        #expect(UsageSorting.weeklyRunway(in: usage, now: now) == 0)
    }

    /// A reset that already passed, or is passing right now, means the quota is about to be
    /// replenished — the LEAST urgent thing on screen, not the most.
    @Test("a reset in the past or right now reads as least urgent, never as a divide-by-zero")
    func pastOrImmediateResetIsLeastUrgent() {
        for hours in [-24.0, -0.001, 0.0] {
            let usage = PlanUsage(windows: [window("seven_day", used: 100, resetsInHours: hours)])
            let r = UsageSorting.weeklyRunway(in: usage, now: now)
            #expect(r == .infinity, "hours=\(hours) should read as least urgent, got \(String(describing: r))")
        }
    }

    /// 0 remaining ÷ 0 hours is the one input that would produce NaN, and a NaN silently
    /// corrupts every comparison it touches (the #110 lesson). It must resolve explicitly.
    @Test("exhausted AND resetting now is least urgent, not NaN")
    func exhaustedAndResettingNowIsNotNaN() {
        let usage = PlanUsage(windows: [window("seven_day", used: 100, resetsInHours: 0)])
        let r = UsageSorting.weeklyRunway(in: usage, now: now)
        #expect(r?.isNaN == false)
        #expect(r == .infinity)
    }

    @Test("a window with no reset time cannot be scored")
    func noResetTimeHasNoKey() {
        let usage = PlanUsage(windows: [window("seven_day", used: 50, resetsInHours: nil)])
        #expect(UsageSorting.weeklyRunway(in: usage, now: now) == nil)
    }

    /// Same isFinite discipline #110 established: an unreadable reading must not participate.
    @Test("a non-finite utilization is skipped rather than scored")
    func nonFiniteIsSkipped() {
        let usage = PlanUsage(windows: [
            window("seven_day", used: .nan, resetsInHours: 1),
            window("weekly_scoped:Opus", used: 50, resetsInHours: 10),   // runway 5.0
        ])
        let r = UsageSorting.weeklyRunway(in: usage, now: now)
        #expect(abs((r ?? -1) - 5.0) < 0.0001, "the NaN window should not have scored")
    }

    @Test("an empty window list has no key")
    func emptyHasNoKey() {
        #expect(UsageSorting.weeklyRunway(in: PlanUsage(windows: []), now: now) == nil)
    }
}

/// The ordering itself, kept generic over "something carrying a LoadState" so it is
/// testable without constructing `@MainActor` row models.
@Suite("UsageSorting.sorted")
@MainActor
struct UsageSortingOrderTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Row {
        let name: String
        let state: AccountUsageModel.LoadState
    }

    private func loaded(used: Double, resetsInHours: Double) -> AccountUsageModel.LoadState {
        .loaded(
            PlanUsage(windows: [UsageWindow(
                id: "seven_day", label: "每週", utilization: used,
                resetsAt: now.addingTimeInterval(resetsInHours * 3600))]),
            fetchedAt: now)
    }

    private func order(_ rows: [Row], _ by: UsageSortOrder) -> [String] {
        UsageSorting.sorted(rows, by: by, now: now, state: \.state).map(\.name)
    }

    @Test("registry order is the input order, untouched")
    func registryIsIdentity() {
        let rows = [
            Row(name: "C", state: loaded(used: 99, resetsInHours: 5)),
            Row(name: "A", state: loaded(used: 92, resetsInHours: 72)),
            Row(name: "B", state: loaded(used: 20, resetsInHours: 4)),
        ]
        #expect(order(rows, .registry) == ["C", "A", "B"])
    }

    @Test("urgency order puts the shortest runway first")
    func urgencyOrders() {
        let rows = [
            Row(name: "B", state: loaded(used: 20, resetsInHours: 4)),
            Row(name: "A", state: loaded(used: 92, resetsInHours: 72)),
            Row(name: "C", state: loaded(used: 99, resetsInHours: 5)),
        ]
        #expect(order(rows, .weeklyUrgency) == ["A", "C", "B"])
    }

    /// Accounts that cannot be scored (still loading, failed, no credentials, or loaded with
    /// no weekly window) sink — and hold their registry order among themselves, so a refresh
    /// does not shuffle them (#112 Risk 2).
    @Test("unscorable accounts sink to the bottom in their original order")
    func unscorableSink() {
        let rows = [
            Row(name: "loading", state: .loading),
            Row(name: "urgent", state: loaded(used: 99, resetsInHours: 72)),
            Row(name: "failed", state: .failed("boom")),
            Row(name: "relaxed", state: loaded(used: 10, resetsInHours: 1)),
            Row(name: "noCreds", state: .noCredentials),
        ]
        #expect(order(rows, .weeklyUrgency) == ["urgent", "relaxed", "loading", "failed", "noCreds"])
    }

    /// Swift's `sort` is not guaranteed stable, so equal runways must fall back to the
    /// original index explicitly — otherwise the list reshuffles on every refresh.
    @Test("equal runways keep their original relative order")
    func tiesAreStable() {
        let rows = (1...6).map { Row(name: "acct-\($0)", state: loaded(used: 50, resetsInHours: 10)) }
        #expect(order(rows, .weeklyUrgency) == rows.map(\.name))
    }

    @Test("an empty list sorts to an empty list in both orders")
    func emptyList() {
        #expect(order([], .registry).isEmpty)
        #expect(order([], .weeklyUrgency).isEmpty)
    }
}
