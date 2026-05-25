import SwiftUI

struct TopPanesView: View {

    @Environment(WindowLayoutState.self) private var layout

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                EditorPanePlaceholder()
                    .frame(width: geo.size.width * (1 - layout.pdfPaneWidthFraction))

                Divider()

                PDFPanePlaceholder()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
