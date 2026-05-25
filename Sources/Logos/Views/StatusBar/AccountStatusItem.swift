import SwiftUI

struct AccountStatusItem: View {
    @Environment(StatusBarViewModel.self) private var vm

    var body: some View {
        Label(vm.accountName, systemImage: "person.crop.circle")
            .font(.caption)
            .help("Click to switch account (sub-plan E)")
    }
}
