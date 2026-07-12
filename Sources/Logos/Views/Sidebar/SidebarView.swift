import SwiftUI

struct SidebarView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ActivityBarSelection.self) private var activityBar

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader()
            Divider()
            if activityBar.active == .files {
                if workspace.roots.isEmpty {
                    noWorkspaceView
                } else {
                    // #96: one collapsible section per workspace root, in folder order.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(workspace.roots, id: \.id) { root in
                                FileTreeView(root: root)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                placeholderForOtherTabs
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var noWorkspaceView: some View {
        VStack(spacing: 8) {
            Text("No workspace open")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("File → Open Workspace…  Your last-opened workspace auto-loads on next launch.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Spacer()
        }
        .padding(.top, 12)
    }

    private var placeholderForOtherTabs: some View {
        VStack {
            Text("Content for \(activityBar.active.label) tab")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(8)
    }
}
