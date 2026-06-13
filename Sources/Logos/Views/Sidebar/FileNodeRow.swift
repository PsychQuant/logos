import SwiftUI

struct FileNodeRow: View {
    let node: FileNode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(node.isProtected ? Color.secondary
                                 : (node.kind == .directory ? Color.accentColor : Color.secondary))
                .frame(width: 14)
            Text(node.displayName)
                .font(.caption)
                .lineLimit(1)
            if node.isProtected {
                // #13: surfaced TCC-protected / unreadable directory — shown so it
                // doesn't silently vanish, but dimmed + locked + non-expandable.
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .help("Protected folder — not expanded to avoid a system permission prompt")
            }
            Spacer(minLength: 0)
        }
        .opacity(node.isProtected ? 0.55 : 1)
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .accessibilityIdentifier("logos.sidebar.fileRow")  // #38: shared row id; node.displayName label distinguishes
    }

    private var icon: String {
        if node.isProtected { return "folder.badge.questionmark" }
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
