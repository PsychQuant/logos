import SwiftUI

struct FileTooLargeBanner: View {
    let path: String
    let actualBytes: Int
    let maxBytes: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("File too large for preview")
                .font(.headline)
            Text("\(actualBytes / 1024) KB exceeds the \(maxBytes / 1024 / 1024) MB cap.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open in external editor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}
