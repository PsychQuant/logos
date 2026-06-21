import SwiftUI

struct TokenUsageStatusItem: View {
    // #47: real per-window usage, driven from THIS window's account session transcript.
    @Environment(WindowUsageModel.self) private var usage

    var body: some View {
        Label(usage.formatted, systemImage: "chart.bar")
            .font(.caption)
            .help("Context-window tokens used / max — from the newest session transcript for this window's account (#47)")
            .accessibilityIdentifier("logos.statusbar.tokenUsage")  // #38
    }
}
