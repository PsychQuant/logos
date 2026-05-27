import SwiftUI

struct MainView: View {

    @Environment(WindowLayoutState.self) private var layout
    @Environment(ActivityBarSelection.self) private var activityBar
    @Environment(StatusBarViewModel.self) private var statusBar
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        @Bindable var layout = layout

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ActivityBarView()

                if activityBar.isVisible && !layout.isSidebarHidden {
                    SidebarView()
                        .frame(width: layout.sidebarWidth)

                    ResizableDivider(axis: .vertical) { delta in
                        layout.sidebarWidth = max(0, layout.sidebarWidth + delta)
                    }
                }

                MainAreaView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider()
            StatusBarView()
        }
        .overlay {
            if workspace.isLoading {
                ProgressView("Loading workspace…")
                    .padding(24)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
