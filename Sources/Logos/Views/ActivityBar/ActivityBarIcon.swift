import SwiftUI

struct ActivityBarIcon: View {

    let tab: ActivityBarSelection.Tab
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.systemImage)
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
        .accessibilityLabel(tab.label)
        .accessibilityIdentifier("logos.activitybar.icon")  // #38: shared id; tab.label distinguishes
    }
}
