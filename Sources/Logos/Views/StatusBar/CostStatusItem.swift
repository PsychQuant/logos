import SwiftUI

struct CostStatusItem: View {
    // #48: real per-window session cost, derived from THIS window's account session transcript
    // (token counts x per-model pricing), same source as TokenUsageStatusItem.
    @Environment(WindowUsageModel.self) private var usage

    var body: some View {
        Label(usage.sessionCostFormatted, systemImage: "dollarsign.circle")
            .font(.caption)
            .help("Estimated API-equivalent session cost: what this session's tokens would cost on the pay-per-use API (ccusage parity). It may differ from your actual subscription bill. A trailing \"+?\" means a model with no known price was used, so the figure is a lower bound. Read-only from the session transcript (#48).")
            .accessibilityIdentifier("logos.statusbar.cost")  // #38
    }
}
