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
    /// The account id this window currently shows. `nil` until seeded on appear
    /// (and again if it resolves to a since-deleted account).
    var accountId: String?

    init(accountId: String? = nil) {
        self.accountId = accountId
    }
}
