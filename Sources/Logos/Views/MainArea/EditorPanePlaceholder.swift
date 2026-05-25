import SwiftUI

struct EditorPanePlaceholder: View {
    var body: some View {
        VStack {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Editor / file viewer")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Content loaded in sub-plan F")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}
