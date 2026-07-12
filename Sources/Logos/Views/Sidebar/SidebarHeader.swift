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
            .accessibilityIdentifier("logos.sidebar.dotfilesToggle")  // #38
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var workspaceName: String {
        let roots = workspace.roots
        guard let first = roots.first else { return "NO WORKSPACE" }
        // Single root → the folder name; multi-root (#96) → a workspace-level title
        // (the per-root folder names are shown by each root section below).
        if roots.count == 1 {
            return (first.path as NSString).lastPathComponent.uppercased()
        }
        return "WORKSPACE (\(roots.count) FOLDERS)"
    }
}
