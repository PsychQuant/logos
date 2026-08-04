import Foundation

/// #112: how 帳號用量 orders its rows.
///
/// A `Picker`-backed enum rather than a boolean toggle, deliberately: the 2026-08-04
/// ruling chose one of *three* candidate urgency algorithms, and the issue itself floated a
/// fourth ordering (plain remaining percent). A two-state toggle would have to be replaced
/// the first time a third order is wanted.
public enum UsageSortOrder: String, CaseIterable, Codable, Identifiable, Sendable {
    public var id: String { rawValue }

    /// The registry's own order — stable and position-predictable. The pre-#112 behaviour.
    case registry
    /// Shortest runway first: the account most likely to leave you stuck.
    case weeklyUrgency

    public var label: String {
        switch self {
        case .registry: return "帳號順序"
        case .weeklyUrgency: return "重置緊迫度"
        }
    }
}

/// #112: the ordering itself — pure, clock-free, and independently testable.
public enum UsageSorting {

    /// Is this window one of the account's WEEKLY budgets?
    ///
    /// Two shapes reach us from `UsageClient`: the all-models `seven_day`, and any number of
    /// per-model `weekly_scoped:<model>` windows (#94). The five-hour session window is a
    /// different budget entirely and must never steer a weekly ordering.
    static func isWeekly(_ window: UsageWindow) -> Bool {
        window.id == "seven_day" || window.id.hasPrefix("weekly_scoped:")
    }

    /// Remaining quota per hour of waiting — **lower is more urgent**. `nil` means the
    /// account cannot be scored at all.
    ///
    /// This is the ruling's definition (2026-08-04). It beats the two simpler candidates
    /// because it is the only one that folds in BOTH halves of the question the issue poses:
    /// 快重置但還剩 90% 並不緊迫；剩 5% 且還要等三天才緊迫.
    ///
    /// The account's score is the **most urgent** of its weekly windows, not an average:
    /// what blocks you is *any* budget running out, so a per-model weekly can strand you
    /// while the all-models one still looks healthy.
    ///
    /// Boundary handling is explicit rather than emergent, because a single NaN silently
    /// corrupts every comparison it reaches (the #110 lesson):
    ///
    /// - reset already passed, or is exactly now → `.infinity` (the quota is about to be
    ///   replenished — the LEAST urgent thing on screen). This is also what keeps
    ///   `0 remaining ÷ 0 hours` from ever evaluating to NaN.
    /// - non-finite `utilization` → that window does not participate at all
    /// - no `resetsAt` → that window cannot be scored
    /// - no scorable weekly window → `nil`, and the caller sinks the row
    public static func weeklyRunway(in usage: PlanUsage, now: Date) -> Double? {
        var best: Double?
        for window in usage.windows where isWeekly(window) {
            guard window.utilization.isFinite, let resetsAt = window.resetsAt else { continue }
            let hours = resetsAt.timeIntervalSince(now) / 3600
            // Guard BEFORE dividing: this is the only branch that could produce 0/0.
            let runway = hours > 0 ? window.percentRemaining / hours : .infinity
            best = best.map { Swift.min($0, runway) } ?? runway
        }
        return best
    }

    /// The runway for a row in any load state — `nil` for every state that carries no usage.
    public static func runway(for state: AccountUsageModel.LoadState, now: Date) -> Double? {
        guard case let .loaded(usage, _) = state else { return nil }
        return weeklyRunway(in: usage, now: now)
    }

    /// Order rows for display.
    ///
    /// Generic over "something that carries a `LoadState`" so the ordering can be tested
    /// without constructing `@MainActor` row models — and so the view passes `\.state`.
    ///
    /// `now` is injected, never read here (#112 Risk 1): a sort that reads the clock is
    /// untestable, and would also let the list reorder itself while the user is looking at it.
    ///
    /// Ties fall back to the original index **explicitly**. Swift's `sort` is not guaranteed
    /// stable, and without this the rows that share a runway — most obviously every
    /// unscorable row — would reshuffle on each refresh (#112 Risk 2).
    public static func sorted<T>(
        _ items: [T],
        by order: UsageSortOrder,
        now: Date,
        state: (T) -> AccountUsageModel.LoadState
    ) -> [T] {
        switch order {
        case .registry:
            return items
        case .weeklyUrgency:
            return items.enumerated()
                .map { (index: $0.offset, item: $0.element, runway: runway(for: state($0.element), now: now)) }
                .sorted { lhs, rhs in
                    switch (lhs.runway, rhs.runway) {
                    case let (l?, r?):
                        return l == r ? lhs.index < rhs.index : l < r
                    case (_?, nil):
                        return true             // scorable outranks unscorable
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        return lhs.index < rhs.index
                    }
                }
                .map(\.item)
        }
    }
}
