import SwiftUI
import LogoSwitch

/// Root of every window in the value-based `WindowGroup` (#42).
///
/// Owns THIS window's `WindowAccountSelection` (which account it shows), seeds it
/// from the scene-presented/restored value (falling back to the global new-window
/// default), mirrors changes back to the presented value so that *if* the OS restores
/// the window it can reopen on the same account (scene restoration is not yet opted-in
/// — see #43), re-seeds when the account list changes so a deleted account never
/// strands the window, titles the window with the account label, and injects the
/// selection into `MainView`'s subtree. The account list + per-account isolation stay
/// global on the injected `AccountManager`.
struct WindowRoot: View {
    @Environment(AccountManager.self) private var accountManager
    @Binding var presentedAccountID: String?
    @State private var selection = WindowAccountSelection()
    /// #47: this window's live token/context usage, driven from its account's session transcript.
    @State private var usage = WindowUsageModel()
    /// #111: the app-level census of which accounts windows are using — the 帳號用量
    /// window's 使用中 chip reads it. Injected rather than owned: it is deliberately ONE
    /// instance across every window (that cross-window view is the entire point).
    @Environment(AccountWindowCensus.self) private var census
    /// #111: this window's entry in the census, plus the `isolated deinit` teardown
    /// backstop. `@State` so SwiftUI keeps it for as long as it keeps this view's state —
    /// in practice the window's life, though SwiftUI does not contractually promise the
    /// two coincide, which is exactly why the ticket also carries the deinit backstop
    /// (#111 verify, codex LOW: the earlier wording claimed a guarantee SwiftUI does not give).
    @State private var censusTicket = WindowCensusTicket()

    var body: some View {
        MainView()
            .environment(selection)
            .environment(usage)
            .navigationTitle(windowTitle)
            .onAppear {
                seedIfNeeded()
                usage.track(configDir: currentConfigDir)
                // #111: this window is now showing an account — record it so 帳號用量's
                // 使用中 chip reflects reality. Keyed by the ticket's stable token, so a
                // re-entrant onAppear re-registers rather than double-counting.
                censusTicket.appear(in: census, accountId: selection.accountId)
            }
            // #47 verify (Codex F3): stop the usage FileWatcher promptly when the window closes,
            // rather than waiting for the model to dealloc. #91 added an `isolated deinit`
            // backstop on both `WindowUsageModel` and `FileWatcher` (Swift 6.1 SE-0371), so a
            // missed onDisappear no longer leaks a live FSEventStream — but this explicit stop
            // is still the prompt path on window close (same pattern as PDFLivePreviewModel).
            .onDisappear {
                usage.track(configDir: nil)
                // #111: same two-layer teardown. This is the prompt path; the ticket's
                // `isolated deinit` covers a missed onDisappear, because a leak here
                // strands an account permanently labelled 使用中 — the same silently-wrong
                // readout this issue removes. `removeWindow` is idempotent, so both
                // layers firing is harmless.
                censusTicket.release()
            }
            // Mirror the window-local selection back to the presented value so that IF
            // the OS restores the window it can reopen on the same account. Scene
            // restoration is not yet opted-in (#43), so this may currently be inert —
            // it is harmless either way. Setting `presentedAccountID` never feeds back
            // into `selection.accountId`, so there is no cycle.
            .onChange(of: selection.accountId) { _, newValue in
                presentedAccountID = newValue
                // #47: re-point usage at the now-active account's session transcript.
                usage.track(configDir: currentConfigDir)
                // #111: THE fix for the reported bug — a switch MOVES this window's
                // census entry, so 帳號用量's chip leaves the old row and lands on the
                // new one. The pre-#111 chip watched `AccountManager.activeAccountId`,
                // which this path deliberately never writes (#42), so it never moved.
                censusTicket.move(to: newValue)
            }
            // #42 verify (DA-1/M1 + DA-2/M2): when the account list changes, drop a
            // since-deleted selection (else this window is stranded on
            // NoActiveAccountBanner until relaunch) and seed an empty-at-launch window
            // once accounts exist. Keeps a still-live selection untouched.
            .onChange(of: accountManager.accounts) { _, newAccounts in
                selection.accountId = WindowAccountResolver.reseededId(
                    current: selection.accountId,
                    default: accountManager.activeAccountId,
                    accounts: newAccounts
                )
            }
    }

    private var windowTitle: String {
        WindowAccountResolver.resolve(
            selected: selection.accountId,
            accounts: accountManager.accounts
        )?.label ?? "Logos"
    }

    /// The config dir of the window's currently-shown account (#47 usage source), or nil.
    /// #55 C4: `usageConfigDir`, not `configDirPath` — for a Main-bound window the real
    /// transcripts live under `~/.claude` (the system-default reuses it and never
    /// materializes its per-account dir), so the status bar must read there.
    private var currentConfigDir: String? {
        WindowAccountResolver.resolve(
            selected: selection.accountId,
            accounts: accountManager.accounts
        )?.usageConfigDir
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
///
/// #44: `openWindow(value:)` dedups by value — opening a window for an account that
/// already has one *raises* the existing window instead of creating a duplicate. This is
/// intentional (prevents accidental multi-window clutter for one account); after an
/// in-window switch rewrites a window's account, the dedup key moves with it.
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
