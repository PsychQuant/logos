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
    public let limitDollars: Double?
    public let remainingDollars: Double?

    public init(
        id: String,
        label: String,
        utilization: Double,
        resetsAt: Date? = nil,
        limitDollars: Double? = nil,
        remainingDollars: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.limitDollars = limitDollars
        self.remainingDollars = remainingDollars
    }

    /// Percent of the window still available, clamped to 0–100.
    public var percentRemaining: Double { max(0, min(100, 100 - utilization)) }
}

/// Aggregated plan usage for a single account. An empty `windows` array is a
/// valid, non-error state (endpoint responded but exposed no known windows) —
/// distinct from a failed fetch, which surfaces as a thrown `UsageError`.
public struct PlanUsage: Equatable, Sendable {
    public let windows: [UsageWindow]
    public init(windows: [UsageWindow]) { self.windows = windows }
}
