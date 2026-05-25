import SwiftUI

struct ActivityBarView: View {

    @Environment(ActivityBarSelection.self) private var selection

    var body: some View {
        VStack(spacing: 0) {
            // Files / Search / Sessions go top
            ForEach([ActivityBarSelection.Tab.files,
                     .search,
                     .sessions], id: \.self) { tab in
                ActivityBarIcon(
                    tab: tab,
                    isActive: selection.active == tab && selection.isVisible,
                    action: { selection.select(tab) }
                )
            }

            Spacer()

            // Settings / Account pinned bottom
            ForEach([ActivityBarSelection.Tab.settings,
                     .account], id: \.self) { tab in
                ActivityBarIcon(
                    tab: tab,
                    isActive: selection.active == tab && selection.isVisible,
                    action: { selection.select(tab) }
                )
            }
        }
        .frame(width: 36)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }
}
