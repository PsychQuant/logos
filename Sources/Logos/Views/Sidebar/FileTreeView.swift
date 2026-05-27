import SwiftUI

struct FileTreeView: View {
    let root: FileNode
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(filtered(root.children ?? []), id: \.id) { child in
                    nodeView(child, depth: 0)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Recursive view returning AnyView to break `some View` self-reference.
    /// AnyView's perf cost is acceptable for file-tree scale.
    private func nodeView(_ node: FileNode, depth: Int) -> AnyView {
        let isActive = workspace.activeTab?.path == node.path

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
