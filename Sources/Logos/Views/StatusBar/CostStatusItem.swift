import SwiftUI

struct CostStatusItem: View {
    // #48: real per-window session cost, derived from THIS window's account session transcript
    // (token counts x per-model pricing), same source as ContextUsageStatusItem.
    @Environment(WindowUsageModel.self) private var usage

    var body: some View {
        // #90: split icon + value (icon `.secondary`) so the segment matches the HUD's
        // icon-marked coding; the `+?` sentinel and identifier are preserved.
        HStack(spacing: 5) {
            Image(systemName: "dollarsign.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(usage.sessionCostFormatted)
                .font(.caption)
                .monospacedDigit()
        }
        .help("Estimated API-equivalent session cost: what this session's tokens would cost on the pay-per-use API (ccusage parity). It may differ from your actual subscription bill. A trailing \"+?\" means a model with no known price was used, so the figure is a lower bound. Read-only from the session transcript (#48).")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session cost \(usage.sessionCostFormatted)")
        .accessibilityIdentifier("logos.statusbar.cost")  // #38
    }
}
