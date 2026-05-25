import SwiftUI

struct MainAreaView: View {

    @Environment(WindowLayoutState.self) private var layout

    var body: some View {
        @Bindable var layout = layout

        GeometryReader { geo in
            VStack(spacing: 0) {
                TopPanesView()
                    .frame(height: geo.size.height * layout.topAreaHeightFraction)

                ResizableDivider(axis: .horizontal) { delta in
                    let newFraction = layout.topAreaHeightFraction + (delta / geo.size.height)
                    layout.topAreaHeightFraction = newFraction
                }

                TerminalPanePlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
