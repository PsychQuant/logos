import SwiftUI

struct ActivityBarView: View {

    @Environment(ActivityBarSelection.self) private var selection
    @Environment(WindowLayoutState.self) private var layout
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // Browsable panels (Files / Search / Sessions) select a tab and
            // toggle the sidebar. `Tab` holds only these, so iterate allCases.
            ForEach(ActivityBarSelection.Tab.allCases) { tab in
                ActivityBarIcon(
                    systemImage: tab.systemImage,
                    label: tab.label,
                    // Effective visibility, not the raw flag (#100 verify C1): after a
                    // drag-collapse the flag stays true while the sidebar is gone — the
                    // raw form would leave this icon lit for a vanished panel.
                    isActive: ActivityBarSelection.isShownAsActive(
                        tab: tab, active: selection.active,
                        isVisible: selection.isVisible,
                        sidebarHiddenByWidth: layout.isSidebarHidden
                    ),
                    action: { activate(tab) }
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

    /// Tab click with recovery semantics (#100): the decision lives in the pure,
    /// unit-tested `ActivityBarSelection.clickOutcome` (effective visibility — in the
    /// broken persisted state a plain `select` would toggle the flag off, making the
    /// first recovery click do nothing observable). This glue only dispatches.
    private func activate(_ tab: ActivityBarSelection.Tab) {
        switch ActivityBarSelection.clickOutcome(
            tab: tab, active: selection.active,
            isVisible: selection.isVisible,
            sidebarHiddenByWidth: layout.isSidebarHidden
        ) {
        case .toggleHide:
            selection.select(tab)          // collapse: toggle off
        case .reveal:
            selection.reveal(tab)          // show: never toggles
            layout.revealSidebar()         // restore a usable width if collapsed
        }
    }
}
