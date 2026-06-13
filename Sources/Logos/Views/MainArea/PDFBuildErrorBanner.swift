import SwiftUI

struct PDFBuildErrorBanner: View {
    let stderrTail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Build failed")
                .font(.headline)
            ScrollView {
                Text(stderrTail.isEmpty ? "(no stderr output)" : stderrTail)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(maxHeight: 180)
            .padding(.horizontal, 24)
            Text("Edit the source to retry.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
