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
            // #11: confine the loading indicator to the content area so it never
            // overlaps the status bar (previously attached to the outer VStack).
            .overlay {
                if workspace.isLoading {
                    ProgressView("Loading workspace…")
                        .padding(24)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            Divider()
            StatusBarView()
        }
        .overlay(alignment: .top) {
            // #9: surface load failures instead of a silent blank state.
            if let error = workspace.lastError {
                errorBanner(error.message)
            }
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                workspace.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
