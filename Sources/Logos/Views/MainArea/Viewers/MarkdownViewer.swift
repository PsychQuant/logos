import SwiftUI

struct MarkdownViewer: View {
    let content: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let attributed = try? AttributedString(
                    markdown: content,
                    options: AttributedString.MarkdownParsingOptions(
                        interpretedSyntax: .inlineOnlyPreservingWhitespace
                    )
                ) {
                    Text(attributed)
                } else {
                    Text(content)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}
