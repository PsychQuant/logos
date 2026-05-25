import SwiftUI

struct StatusBarView: View {
    var body: some View {
        HStack(spacing: 12) {
            AccountStatusItem()
            CostStatusItem()
            AutoHandleStatusItem()
            TokenUsageStatusItem()
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
