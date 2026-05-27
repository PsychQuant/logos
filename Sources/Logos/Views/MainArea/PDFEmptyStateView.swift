import SwiftUI

struct PDFEmptyStateView: View {
    let reason: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No live preview")
                .font(.headline)
                .foregroundStyle(.secondary)
            if let r = reason {
                Text(r)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Open a .tex or .md file in the editor to enable live preview.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
