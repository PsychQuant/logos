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
        // #100: every successful workspace open reveals the file explorer (VS Code
        // parity, user-confirmed policy). Observes the monotonic loadCount — not
        // `roots` — so a same-path reopen also fires, and it heals the broken
        // persisted sub-threshold width at launch (auto-load → reveal).
        // Known limits (#100 verify): workspace/layout/activityBar are app-global
        // (N:1 window model, #98), so this fires in every open window at once; and
        // it force-switches the active tab to Files — harmless while Search/Sessions
        // are placeholders, revisit when a real Search panel carries state.
        .onChange(of: workspace.loadCount) {
            activityBar.reveal(.files)
            layout.revealSidebar()
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
        .bannerStyle(material: .thinMaterial)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
