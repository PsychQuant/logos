import Observation

/// Per-window account binding (#42). Each window of the value-based `WindowGroup`
/// owns exactly one of these — it holds ONLY "which account THIS window shows".
///
/// The account list, CRUD, per-account `CLAUDE_CONFIG_DIR` isolation (#12), and
/// live-401 state all stay GLOBAL on `AccountManager` (the launcher model, #34).
/// Switching the account inside a window mutates this `accountId`, NOT the global
/// `AccountManager.activeAccountId` (which is now just the seed for *newly opened*
/// windows) — so windows stay independent (the #42 window-local decision).
@Observable
@MainActor
final class WindowAccountSelection {
    /// The account id this window currently shows. `nil` until `WindowRoot` seeds it on
    /// appear; `WindowRoot` also re-seeds it (via `WindowAccountResolver.reseededId`)
    /// whenever the account list changes — e.g. this window's account was deleted — so a
    /// window is never stranded on a dead id (#42 verify, DA-1).
    var accountId: String?

    init(accountId: String? = nil) {
        self.accountId = accountId
    }
}
