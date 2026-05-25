import SwiftUI

struct AutoHandleStatusItem: View {
    @Environment(StatusBarViewModel.self) private var vm

    var body: some View {
        Label(vm.autoHandleStatus.label, systemImage: "bolt.fill")
            .font(.caption)
            .foregroundStyle(vm.autoHandleStatus.color)
            .help("Auto-handle pattern engine status (wired in sub-plan D)")
    }
}
