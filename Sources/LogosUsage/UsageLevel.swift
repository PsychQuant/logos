import SwiftUI

/// #90 / #110: the colour band a usage bar sits in, keyed on the CONSUMED
/// fraction (0 = empty, 1 = full). Every usage surface feeds a consumed
/// fraction, so a higher value is always worse — one classification serves the
/// status bar's context + plan bars and the 帳號用量 window's plan bars alike.
/// Bands: green below 0.70, yellow in 0.70..<0.90, red at/above 0.90.
///
/// #110 moved this down from the app module (where it was `HUDUsageLevel`,
/// next to `HUDProgressBar`) into `LogosUsage`. `AccountRowView`'s `UsageBar`
/// lives in this library and `Logos` depends on `LogosUsage`, not the reverse —
/// so the only way both surfaces can share one set of thresholds is for the
/// classification to live here. The "HUD" prefix went with the move: this type
/// no longer belongs to the status bar.
///
/// The classification is pure (no view state) so it unit-tests directly; the
/// `color` mapping is a thin SwiftUI adapter the views read.
public enum UsageLevel: Equatable, Sendable {
    case nominal
    case warning
    case critical

    /// A non-finite input (a `0/0` divide on a fresh session, or ±∞) collapses to the
    /// nominal band so an empty bar never flashes red. A negative value is below every
    /// threshold and is likewise nominal.
    public init(fraction: Double) {
        let f = fraction.isFinite ? fraction : 0
        switch f {
        case ..<0.70: self = .nominal
        case ..<0.90: self = .warning
        default: self = .critical
        }
    }

    public var color: Color {
        switch self {
        case .nominal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}
