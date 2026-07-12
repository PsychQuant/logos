import SwiftUI

/// #90: the bottom status bar, restyled as a claude-hud-style HUD — segmented,
/// icon-marked, colour-coded, with green→yellow→red fill bars for context and
/// plan usage. Each segment keeps its prior behaviour (the account switcher, the
/// cost `+?` sentinel, the auto-handle state); the two text usage readouts become
/// `HUDProgressBar`s. Hairline `HUDDivider`s separate the segments.
struct StatusBarView: View {
    var body: some View {
        HStack(spacing: 10) {
            AccountStatusItem()
            HUDDivider()
            CostStatusItem()
            HUDDivider()
            AutoHandleStatusItem()
            HUDDivider()
            ContextUsageStatusItem()
            HUDDivider()
            PlanUsageStatusItem()
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
