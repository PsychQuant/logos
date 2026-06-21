import SwiftUI

struct CostStatusItem: View {
    @Environment(StatusBarViewModel.self) private var vm

    var body: some View {
        Label(vm.sessionCostFormatted, systemImage: "dollarsign.circle")
            .font(.caption)
            .help("Session running cost — still a placeholder; real-cost wiring deferred to #48 (the transcript has no cost field; it must be derived). #47 wired token/context.")
            .accessibilityIdentifier("logos.statusbar.cost")  // #38
    }
}
