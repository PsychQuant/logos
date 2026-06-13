import SwiftUI

struct FileTabBar: View {
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.openTabs) { tab in
                    tabItem(tab)
                }
            }
        }
        .frame(height: 30)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func tabItem(_ tab: OpenFileTab) -> some View {
        let isActive = workspace.activeTab?.id == tab.id
        return HStack(spacing: 6) {
            Image(systemName: iconFor(extension: (tab.path as NSString).pathExtension))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tab.displayName)
                .font(.caption)
                .lineLimit(1)
            Button(action: { workspace.closeTab(path: tab.path) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .accessibilityIdentifier("logos.editor.tabClose")  // #38
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isActive ? Color(NSColor.controlAccentColor).opacity(0.15) : .clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.setActive(path: tab.path) }
        .accessibilityIdentifier("logos.editor.tab")  // #38: shared tab id; tab.displayName label distinguishes
    }

    private func iconFor(extension ext: String) -> String {
        switch ext.lowercased() {
        case "swift": "swift"
        case "md": "doc.text"
        case "json", "yaml", "yml", "toml": "curlybraces"
        case "tex": "function"
        case "py", "rb", "js", "ts", "go", "rs": "chevron.left.forwardslash.chevron.right"
        default: "doc"
        }
    }
}
