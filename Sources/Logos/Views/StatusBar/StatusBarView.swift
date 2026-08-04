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
            // #116: the session's environment (CLI version + git branch) sits in its OWN
            // segment, further left than the model — the user's 2026-08-04 ruling.
            SessionEnvironmentStatusItem()
            HUDDivider()
            CostStatusItem()
            HUDDivider()
            AutoHandleStatusItem()
            HUDDivider()
            // #116: model + effort immediately LEFT of the context counter, per the same
            // ruling ("在 token 還剩多少的左邊", "effort 在 model 旁邊").
            ModelStatusItem()
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
