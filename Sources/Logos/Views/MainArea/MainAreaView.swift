import SwiftUI

struct MainAreaView: View {

    @Environment(WindowLayoutState.self) private var layout

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                TopPanesView()
                    .frame(height: geo.size.height * layout.topAreaHeightFraction)

                Divider()

                TerminalPanePlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
