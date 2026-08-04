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
/// `WindowRoot` is a `View` (a struct) with no deinit of its own, so this object is held
/// as its `@State` and deregisters in an `isolated deinit` — the same two-layer teardown
/// #91 adopted for `WindowUsageModel` / `FileWatcher` (SE-0371, Swift 6.1+) after #47
/// verify found that a missed `onDisappear` leaked a live FSEventStream.
/// `WindowRoot.onDisappear` is the prompt path; the deinit only covers a missed one, and
/// runs whenever ARC releases the ticket — **eventually**, not at a guaranteed instant
/// (#111 verify, regression lens: the earlier wording overstated this). `removeWindow`
/// is idempotent precisely so both layers can fire.
///
/// **Why an explicit lifecycle phase rather than one `bind` method** (#111 verify, codex
/// + logic, HIGH): `onAppear` / `onChange` / `onDisappear` are independent SwiftUI
/// modifiers with no ordering guarantee between them, so a single method serving both
/// "register" and "move" let `release()` be silently undone. That is not a theoretical
/// ordering worry — `WindowRoot` has a *second* `onChange(of: accountManager.accounts)`
/// that writes `selection.accountId` to re-seed a window off a deleted account, which
/// cascades into the selection `onChange`. Another window deleting an account was
/// therefore enough to resurrect a released token and strand an account permanently
/// labelled 使用中: exactly the silent wrongness #111 exists to remove.
///
/// **Why three phases and not a bool** (#111 verify, devil's advocate): a two-layer
/// teardown only guards *over*-counting. Guarding a move behind "已註冊" would trade that
/// for *under*-counting — a window whose `onAppear` never landed could then never be
/// counted, and unlike an over-count nothing later corrects it. `pending` keeps the
/// self-heal (a move before any appear still registers) while `released` stays terminal.
@MainActor
final class WindowCensusTicket {

    /// Where this window sits in its registration lifecycle. The two non-`registered`
    /// cases are deliberately NOT symmetric: `pending` self-heals forward, `released` is
    /// terminal.
    private enum Phase {
        /// Never appeared. A move arriving first still registers — the view is in the
        /// hierarchy (that is what fired the change), so it should be counted.
        case pending
        /// Appeared and counted.
        case registered
        /// Torn down. A late move must NOT resurrect the entry.
        ///
        /// Terminal for `move` only. A later `appear` DOES re-register, and that is
        /// correct rather than a hole: `onAppear` firing again means the view returned to
        /// the hierarchy, so the window must be counted again. Guarding `appear` here —
        /// which three round-2 lenses independently proposed — would turn every
        /// disappear/reappear cycle into a permanent under-count that nothing corrects
        /// (#111 verify round 2, devil's advocate, refuting the other lenses).
        case released
    }

    /// Identity of this window inside the census. Stable for the window's whole life, so
    /// a re-entrant `onAppear` re-registers the same key instead of adding a second one.
    let token = UUID()

    /// Set once the view has the census from the environment. Held strongly: the census
    /// is an app-lifetime object that holds no reference back, so there is no cycle.
    private var census: AccountWindowCensus?
    private var phase: Phase = .pending

    init() {}

    /// `onAppear`: start (or restart) counting this window.
    ///
    /// Re-appearing against a *different* census instance drops the entry in the old one
    /// first, so a re-created app-level census cannot leave an orphan behind.
    func appear(in census: AccountWindowCensus, accountId: String?) {
        if let previous = self.census, previous !== census {
            previous.removeWindow(token)
        }
        self.census = census
        phase = .registered
        census.setAccount(accountId, forWindow: token)
    }

    /// `onChange(of: selection.accountId)`: move this window's mark to another account.
    ///
    /// **Takes the census** rather than relying on a stored one (#111 verify round 2 —
    /// five lenses, correctly). Round 2 stored the census only in `appear`, so at
    /// `.pending` it was still nil and the guard returned early: the "a move before any
    /// appear still self-heals" the type claimed was structurally unreachable, and the
    /// test named `moveBeforeAppearSelfHeals` asserted the *absence* of the self-heal it
    /// was named for. Passing the census in makes `.pending` mean what it says.
    ///
    /// A no-op once released — that half WAS load-bearing: deleting the phase enum turns
    /// `lateMoveAfterReleaseIsInert` red, which refutes the round-2 claim that the whole
    /// machine had no test discrimination.
    func move(to accountId: String?, in census: AccountWindowCensus) {
        guard phase != .released else { return }
        if let previous = self.census, previous !== census {
            previous.removeWindow(token)
        }
        self.census = census
        phase = .registered
        census.setAccount(accountId, forWindow: token)
    }

    /// `onDisappear`: prompt-path deregistration.
    func release() {
        phase = .released
        census?.removeWindow(token)
    }

    /// Backstop for a missed `onDisappear`. Unconditional: if the ticket is being
    /// deallocated the window is gone regardless of which phase it reached, and
    /// `removeWindow` is idempotent so overlapping with `release()` is harmless.
    isolated deinit {
        census?.removeWindow(token)
    }
}
