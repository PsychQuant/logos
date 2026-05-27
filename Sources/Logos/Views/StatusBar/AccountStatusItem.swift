import SwiftUI

struct AccountStatusItem: View {
    @Environment(AccountManager.self) private var mgr
    @State private var showSwitcher = false

    var body: some View {
        Button(action: { showSwitcher = true }) {
            Label(mgr.active?.label ?? "no account", systemImage: "person.crop.circle")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Click to switch / manage accounts (⌘K)")
        .keyboardShortcut("k", modifiers: .command)
        .sheet(isPresented: $showSwitcher) {
            AccountSwitcherSheet()
        }
    }
}
