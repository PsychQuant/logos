import SwiftUI

struct TokenUsageStatusItem: View {
    @Environment(StatusBarViewModel.self) private var vm

    var body: some View {
        Label(vm.tokenUsageFormatted, systemImage: "chart.bar")
            .font(.caption)
            .help("Context window tokens used / max (wired in sub-plan D)")
            .accessibilityIdentifier("logos.statusbar.tokenUsage")  // #38
    }
}
