import SwiftUI

struct FileNodeRow: View {
    let node: FileNode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(node.kind == .directory ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            Text(node.displayName)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }

    private var icon: String {
        guard node.kind == .file else { return "folder" }
        switch node.fileExtension {
        case "swift": return "swift"
        case "md": return "doc.text"
        case "tex": return "function"
        case "pdf": return "doc.richtext"
        case "json", "yaml", "yml", "toml": return "curlybraces.square"
        default: return "doc"
        }
    }
}
