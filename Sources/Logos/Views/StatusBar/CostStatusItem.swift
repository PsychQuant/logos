import SwiftUI

struct CostStatusItem: View {
    @Environment(StatusBarViewModel.self) private var vm

    var body: some View {
        Label(vm.sessionCostFormatted, systemImage: "dollarsign.circle")
            .font(.caption)
            .help("Session running cost (wired in sub-plan D)")
            .accessibilityIdentifier("logos.statusbar.cost")  // #38
    }
}
