import SwiftUI
import PDFKit

struct PDFViewerNSView: NSViewRepresentable {
    let url: URL
    let builtAt: Date  // forces re-render on rebuild

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.windowBackgroundColor
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        load(into: nsView)
    }

    private func load(into view: PDFView) {
        if let doc = PDFDocument(url: url) {
            view.document = doc
        }
    }
}
