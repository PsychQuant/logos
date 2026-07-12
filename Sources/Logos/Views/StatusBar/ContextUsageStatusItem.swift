import SwiftUI

/// #90: the context-window HUD segment — a green→yellow→red fill bar for how full
/// this window's claude session context is, plus the `680k / 1M`-style label. Data
/// is the same per-window `WindowUsageModel` the old `TokenUsageStatusItem` text read
/// (#47/#49); a fresh session reads 0 (#89), so the bar renders empty rather than full.
struct ContextUsageStatusItem: View {
    // #47: real per-window usage, driven from THIS window's account session transcript.
    @Environment(WindowUsageModel.self) private var usage

    /// Consumed fraction of the context window (0…1). Guards a zero/negative max so a
    /// malformed reading can never divide-by-zero — the bar collapses to empty (#89).
    private var fraction: Double {
        guard usage.contextMax > 0 else { return 0 }
        return Double(usage.contextTokens) / Double(usage.contextMax)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.bar.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HUDProgressBar(fraction: fraction)
            Text(usage.formatted)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("Context-window tokens used / max — from the newest session transcript for this window's account (#47). Green under 70% full, yellow 70–90%, red above 90%.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Context usage \(usage.formatted)")
        .accessibilityIdentifier("logos.statusbar.tokenUsage")  // #38 (identifier kept stable)
    }
}
