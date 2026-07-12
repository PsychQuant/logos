import SwiftUI

/// Renders ONE workspace root as a top-level collapsible section (#96): a
/// disclosure header carrying the root folder's name, containing the recursive
/// file tree of that root's children. `SidebarView` owns the surrounding
/// `ScrollView` and renders one `FileTreeView` per root, in folder order.
struct FileTreeView: View {
    let root: FileNode
    @Environment(WorkspaceModel.self) private var workspace
    /// Each root section starts expanded (VS Code shows workspace folders open).
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(filtered(root.children ?? []), id: \.id) { child in
                nodeView(child, depth: 0)
                    .padding(.leading, 12)
            }
        } label: {
            Text(root.displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textCase(.uppercase)
                .accessibilityIdentifier("logos.sidebar.rootSection")  // #96: per-root header
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    /// Recursive view returning AnyView to break `some View` self-reference.
    /// AnyView's perf cost is acceptable for file-tree scale.
    private func nodeView(_ node: FileNode, depth: Int) -> AnyView {
        let isActive = workspace.activeTab?.path == node.path

        // #13: protected directories are opaque leaves — render as a plain,
        // non-expandable row (no DisclosureGroup, no descend) so they show but
        // can't trigger a TCC consent prompt on expansion.
        if node.isProtected {
            return AnyView(
                FileNodeRow(node: node, isSelected: false)
                    .padding(.leading, CGFloat(depth) * 4 + 18)
            )
        }

        if node.kind == .directory {
            return AnyView(
                DisclosureGroup {
                    ForEach(filtered(node.children ?? []), id: \.id) { child in
                        nodeView(child, depth: depth + 1)
                            .padding(.leading, 12)
                    }
                } label: {
                    FileNodeRow(node: node, isSelected: false)
                }
                .padding(.leading, CGFloat(depth) * 4)
            )
        } else {
            return AnyView(
                FileNodeRow(node: node, isSelected: isActive)
                    .padding(.leading, CGFloat(depth) * 4 + 18)
                    .onTapGesture {
                        workspace.openFile(at: node.path)
                    }
            )
        }
    }

    private func filtered(_ nodes: [FileNode]) -> [FileNode] {
        if workspace.showHidden { return nodes }
        return nodes.filter { !$0.isHidden }
    }
}
