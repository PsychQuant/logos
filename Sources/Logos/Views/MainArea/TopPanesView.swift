import SwiftUI

struct TopPanesView: View {

    @Environment(WindowLayoutState.self) private var layout

    var body: some View {
        @Bindable var layout = layout

        GeometryReader { geo in
            HStack(spacing: 0) {
                EditorPanePlaceholder()
                    .frame(width: geo.size.width * (1 - layout.pdfPaneWidthFraction))

                ResizableDivider(axis: .vertical) { delta in
                    // dragging right shrinks PDF pane;
                    // convert delta into PDF fraction delta (inverted)
                    let newPDFFraction = layout.pdfPaneWidthFraction - (delta / geo.size.width)
                    layout.pdfPaneWidthFraction = newPDFFraction
                }

                PDFPanePlaceholder()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
