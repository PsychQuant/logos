import SwiftUI
import LogosUsage

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
                    .fill(UsageLevel(fraction: clamped).color)
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
