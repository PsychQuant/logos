import SwiftUI

/// #90: the colour band a filled HUD bar sits in, keyed on the CONSUMED fraction
/// (0 = empty, 1 = full). Both the context-window bar and the 5-hour plan bar feed
/// a consumed fraction, so a higher value is always worse — one classification serves
/// both. Bands: green below 0.70, yellow in 0.70..<0.90, red at/above 0.90.
///
/// The classification is pure (no SwiftUI) so it unit-tests directly; the `color`
/// mapping is a thin SwiftUI adapter the views read.
enum HUDUsageLevel: Equatable {
    case nominal
    case warning
    case critical

    /// A non-finite input (a `0/0` divide on a fresh session, or ±∞) collapses to the
    /// nominal band so an empty HUD never flashes red. A negative value is below every
    /// threshold and is likewise nominal.
    init(fraction: Double) {
        let f = fraction.isFinite ? fraction : 0
        switch f {
        case ..<0.70: self = .nominal
        case ..<0.90: self = .warning
        default: self = .critical
        }
    }

    var color: Color {
        switch self {
        case .nominal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

/// #90: a compact horizontal fill bar for the status-bar HUD. Renders a muted track
/// with a leading fill whose width and colour track `fraction` (the consumed 0…1
/// fraction). A fresh session (`fraction == 0`) shows an empty track — the fill is
/// zero-width, never a full or crashing bar.
struct HUDProgressBar: View {
    /// Consumed fraction, 0 (empty) … 1 (full). Clamped defensively.
    let fraction: Double
    var width: CGFloat = 46
    var height: CGFloat = 5

    private var clamped: Double {
        let f = fraction.isFinite ? fraction : 0
        return min(max(f, 0), 1)
    }

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(HUDUsageLevel(fraction: clamped).color)
                    .frame(width: width * clamped, height: height)
            }
            .accessibilityHidden(true)
    }
}

/// #90: a hairline separator between HUD segments. Kept short and `.tertiary` so it
/// divides without competing with the segment content.
struct HUDDivider: View {
    var body: some View {
        Rectangle()
            .fill(.tertiary)
            .frame(width: 1, height: 12)
            .accessibilityHidden(true)
    }
}
