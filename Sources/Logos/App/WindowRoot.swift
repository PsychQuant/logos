import SwiftUI
import LogoSwitch

/// Root of every window in the value-based `WindowGroup` (#42).
///
/// Owns THIS window's `WindowAccountSelection` (which account it shows), seeds it
/// from the scene-presented/restored value (falling back to the global new-window
/// default), mirrors changes back to the presented value so window restoration
/// remembers the account, titles the window with the account label, and injects the
/// selection into `MainView`'s subtree. The account list + per-account isolation stay
/// global on the injected `AccountManager`.
struct WindowRoot: View {
    @Environment(AccountManager.self) private var accountManager
    @Binding var presentedAccountID: String?
    @State private var selection = WindowAccountSelection()

    var body: some View {
        MainView()
            .environment(selection)
            .navigationTitle(windowTitle)
            .onAppear(perform: seedIfNeeded)
            // Mirror the window-local selection back to the scene-restored value so a
            // reopened window remembers its account. Setting `presentedAccountID`
            // never feeds back into `selection.accountId`, so there is no cycle.
            .onChange(of: selection.accountId) { _, newValue in
                presentedAccountID = newValue
            }
    }

    private var windowTitle: String {
        WindowAccountResolver.resolve(
            selected: selection.accountId,
            accounts: accountManager.accounts
        )?.label ?? "Logos"
    }

    /// Seed once per window. Guards on `nil` so a SwiftUI re-render (or a window the
    /// user already switched) never re-seeds over the live selection.
    private func seedIfNeeded() {
        guard selection.accountId == nil else { return }
        selection.accountId = WindowAccountResolver.seed(
            presented: presentedAccountID,
            default: accountManager.activeAccountId,
            accounts: accountManager.accounts
        )
    }
}

/// `File ▸ New Window for Account ▸ <account>` (#42). A real `View` (not a bare
/// `.commands` closure) so reading `accountManager.accounts` registers `@Observable`
/// tracking — the submenu stays in sync as accounts are added/renamed/removed.
struct NewWindowForAccountMenu: View {
    let accountManager: AccountManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("New Window for Account") {
            ForEach(accountManager.accounts) { account in
                Button(account.label) { openWindow(value: account.id) }
            }
        }
        .disabled(accountManager.accounts.isEmpty)
    }
}
