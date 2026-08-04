import Foundation
import Observation

/// #111: which accounts are open windows *actually* using, and how many windows each.
///
/// 帳號用量 is a single standalone window, but the account is **per-window** (#42) — so
/// "使用中" is only well-defined as an aggregate across windows. Nothing in the app
/// answered that before this type: each `WindowRoot` owns its `WindowAccountSelection`
/// privately as `@State`, and windows cannot see one another's.
///
/// The chip previously read `AccountManager.activeAccountId`, which #42 demoted to *the
/// seed for newly-opened windows*. An in-window switch writes
/// `WindowAccountSelection.accountId` and deliberately never touches the global id
/// (`AccountSwitcherSheet.selectAccount`), so the chip was bound to a field the switch
/// action structurally cannot write — it could never move. This census replaces that
/// binding with the real thing.
///
/// **Keyed by a per-window token, not by account id.** `onAppear` can re-enter on macOS;
/// token-keying makes a repeat registration idempotent and a deregistration exact, so one
/// window can never inflate its own account's count (#111 Risk 2).
///
/// `GatewayPool` already refcounts per account with the same "two windows on one account
/// share one" semantics, but it excludes the system-default account from the pool and is
/// an actor with a 5s linger — it answers a *process-lifetime* question, not a
/// *window-occupancy* one, so it is prior art rather than a reusable source.
@Observable
@MainActor
final class AccountWindowCensus {

    /// window token → the account that window currently shows. A window with no account
    /// yet (`WindowAccountSelection.accountId` is nil until `WindowRoot` seeds it) simply
    /// holds no entry, so it is counted against nothing.
    private var accountByWindow: [UUID: String] = [:]

    init() {}

    /// How many open windows currently show `accountId` — the number the chip renders as
    /// `使用中 ×N`. Zero means no window has it open, so no chip.
    ///
    /// Takes an optional because a usage row's `registryAccountId` is optional. A row with
    /// no registry id genuinely cannot be open in any window, so 0 is the right answer
    /// rather than a masked error.
    func windowCount(for accountId: String?) -> Int {
        guard let accountId else { return 0 }
        return accountByWindow.values.reduce(into: 0) { count, id in
            if id == accountId { count += 1 }
        }
    }

    /// Every account with at least one window open, sorted for a stable order.
    var activeAccountIds: [String] {
        Set(accountByWindow.values).sorted()
    }

    /// Register this window's account, or move it when the window switches.
    ///
    /// This is a **move**, not an add: re-pointing a token drops its previous account in
    /// the same step, so a switch leaves nothing behind on the old row. Passing `nil`
    /// clears the window's registration (a window can legitimately hold no account).
    func setAccount(_ accountId: String?, forWindow token: UUID) {
        // Assigning nil to a Dictionary subscript removes the key, which is exactly the
        // "clear this window's registration" semantics.
        accountByWindow[token] = accountId
    }

    /// Deregister a closing window.
    ///
    /// **Must tolerate being called more than once for the same token**, and for a token
    /// that was never registered. `WindowRoot` calls this from `onDisappear` (the prompt
    /// path) *and* from an `isolated deinit` backstop, because `onDisappear` is not
    /// guaranteed to fire on window close — the same two-layer pattern #91 adopted for
    /// `WindowUsageModel` / `FileWatcher` after #47 verify found a leaked FSEventStream.
    /// A leak here would be worse than a stale watcher: it strands an account permanently
    /// labelled 使用中, which is precisely the class of silent wrongness #111 is fixing.
    func removeWindow(_ token: UUID) {
        accountByWindow[token] = nil
    }
}

/// #111: one window's registration in the census, plus the teardown backstop.
///
/// `WindowRoot` is a `View` (a struct), so it has no deinit of its own to guarantee
/// deregistration. This object is held as its `@State`, giving it exactly the window's
/// lifetime, and deregisters in an `isolated deinit` — the same two-layer teardown #91
/// adopted for `WindowUsageModel` / `FileWatcher` (SE-0371, Swift 6.1+) after #47 verify
/// found that a missed `onDisappear` leaked a live FSEventStream.
///
/// `WindowRoot.onDisappear` remains the prompt path; this only covers the case where it
/// never fires. Leaking here is worse than leaking a watcher: the account stays
/// permanently labelled 使用中, which is the same silently-wrong readout #111 exists to
/// remove. `removeWindow` is idempotent precisely so both layers can fire.
@MainActor
final class WindowCensusTicket {
    /// Identity of this window inside the census. Stable for the window's whole life, so
    /// a re-entrant `onAppear` re-registers the same key instead of adding a second one.
    let token = UUID()

    /// Set once the view has the census from the environment. Held strongly: the census
    /// is an app-lifetime object that holds no reference back, so there is no cycle.
    private var census: AccountWindowCensus?

    init() {}

    /// Register (or move) this window's account, remembering the census for teardown.
    func bind(_ census: AccountWindowCensus, to accountId: String?) {
        self.census = census
        census.setAccount(accountId, forWindow: token)
    }

    /// Prompt-path deregistration, called from `WindowRoot.onDisappear`.
    func release() {
        census?.removeWindow(token)
    }

    isolated deinit {
        census?.removeWindow(token)
    }
}
