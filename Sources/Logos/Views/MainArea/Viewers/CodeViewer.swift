import SwiftUI
import Highlightr

struct CodeViewer: View {
    let content: String
    let language: String
    @Environment(TerminalConfig.self) private var config

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            highlightedText
                .font(.system(size: config.fontSize, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var highlightedText: Text {
        guard let hl = Highlightr() else {
            return Text(content)
        }
        hl.setTheme(to: "xcode")
        let attributed = hl.highlight(content, as: language, fastRender: true)
            ?? NSAttributedString(string: content)
        return Text(AttributedString(attributed))
    }
}
