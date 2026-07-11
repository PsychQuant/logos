import SwiftUI

struct ActivityBarView: View {

    @Environment(ActivityBarSelection.self) private var selection
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // Browsable panels (Files / Search / Sessions) select a tab and
            // toggle the sidebar. `Tab` holds only these, so iterate allCases.
            ForEach(ActivityBarSelection.Tab.allCases) { tab in
                ActivityBarIcon(
                    systemImage: tab.systemImage,
                    label: tab.label,
                    isActive: selection.active == tab && selection.isVisible,
                    action: { selection.select(tab) }
                )
            }

            Spacer()

            // The gear is an action, not a tab: it opens the Settings window
            // (same target as Cmd+, / the Settings scene) rather than selecting
            // a sidebar panel, so it never marks itself active. Account switching
            // lives in the status bar and is intentionally absent here.
            ActivityBarIcon(
                systemImage: "gearshape",
                label: "Settings",
                isActive: false,
                action: { openSettings() }
            )
        }
        .frame(width: 36)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }
}
