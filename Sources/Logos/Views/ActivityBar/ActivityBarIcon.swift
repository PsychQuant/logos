import SwiftUI

/// A single activity-bar affordance. Presentation-only: it carries a symbol and
/// a label, not whether it selects a sidebar tab or fires a one-shot action — so
/// it serves both the browsable tabs and the standalone Settings gear.
struct ActivityBarIcon: View {

    let systemImage: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(width: 36, height: 36)
                .background(
                    Rectangle()
                        .fill(isActive ? Color.accentColor.opacity(0.15) : .clear)
                )
                .overlay(alignment: .leading) {
                    if isActive {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("logos.activitybar.icon")  // #38: shared id; label distinguishes
    }
}
