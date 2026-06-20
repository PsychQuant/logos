import SwiftUI
import LogoSwitch

struct AccountStatusItem: View {
    @Environment(AccountManager.self) private var mgr
    /// #42: this window's account. The status item shows + switches THIS window's
    /// account, and opens new windows bound to a chosen account.
    @Environment(WindowAccountSelection.self) private var windowSelection
    @Environment(\.openWindow) private var openWindow
    @State private var showSwitcher = false

    var body: some View {
        @Bindable var windowSelection = windowSelection
        Button(action: { showSwitcher = true }) {
            Label(currentLabel, systemImage: "person.crop.circle")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Click to switch / manage accounts (⌘K)")
        .keyboardShortcut("k", modifiers: .command)
        .accessibilityIdentifier("logos.statusbar.accountButton")  // #24 XCUITest query
        .sheet(isPresented: $showSwitcher) {
            AccountSwitcherSheet(
                selection: $windowSelection.accountId,
                onOpenInNewWindow: { openWindow(value: $0) }
            )
        }
    }

    /// This window's account label (per-window), or a placeholder.
    private var currentLabel: String {
        WindowAccountResolver.resolve(
            selected: windowSelection.accountId,
            accounts: mgr.accounts
        )?.label ?? "no account"
    }
}
