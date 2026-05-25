import SwiftUI

struct PDFPanePlaceholder: View {
    var body: some View {
        VStack {
            Image(systemName: "doc.richtext")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("PDF live render")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Content loaded in sub-plan G")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
