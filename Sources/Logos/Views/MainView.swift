import SwiftUI

struct MainView: View {

    @Environment(WindowLayoutState.self) private var layout
    @Environment(ActivityBarSelection.self) private var activityBar
    @Environment(StatusBarViewModel.self) private var statusBar

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ActivityBarView()

                if activityBar.isVisible && !layout.isSidebarHidden {
                    SidebarView()
                        .frame(width: layout.sidebarWidth)
                    Divider()
                }

                MainAreaView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider()
            StatusBarView()
        }
    }
}
