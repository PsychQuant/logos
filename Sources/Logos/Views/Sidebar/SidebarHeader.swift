import SwiftUI

struct SidebarHeader: View {
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        HStack {
            Text(workspaceName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: { workspace.toggleHidden() }) {
                Image(systemName: workspace.showHidden ? "eye" : "eye.slash")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help(workspace.showHidden ? "Hide dotfiles" : "Show dotfiles")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var workspaceName: String {
        guard let root = workspace.rootNode else { return "NO WORKSPACE" }
        return (root.path as NSString).lastPathComponent.uppercased()
    }
}
