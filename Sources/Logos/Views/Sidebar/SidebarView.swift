import SwiftUI

struct SidebarView: View {

    @Environment(ActivityBarSelection.self) private var activityBar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(activityBar.active.label.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            Text("Placeholder — content loaded in sub-plan F (Files), D (Sessions), H (Settings), E (Account)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
