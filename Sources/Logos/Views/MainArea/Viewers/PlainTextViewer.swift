import SwiftUI

struct PlainTextViewer: View {
    let content: String
    @Environment(TerminalConfig.self) private var config

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(content)
                .font(.system(size: config.fontSize, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}
