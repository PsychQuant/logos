import Foundation

/// The ordering invariant for deleting an account (spec 2026-07-31).
///
/// Deleting an account does two things that must happen in this order:
///
///  1. stop the account's gateway child, then
///  2. remove it from the registry — which reaps its data directory inline.
///
/// The gateway writes rate-limit state into `<account dir>/hot-limit`, and the
/// proxy's writer creates that directory if it is missing. Reaping first would let
/// a still-running child recreate the tree the reaper had just deleted, resurrecting
/// the orphan directory `AccountReaper` (#50) exists to prevent.
///
/// Expressed as its own step-ordering function rather than as a hook inside
/// `AccountManager` for two reasons. `LogoSwitch` stays entirely free of any gateway
/// concept — it does not even hold a closure for one. And `AccountManager.remove`
/// keeps its tested SYNCHRONOUS reap contract (`AccountManagerReapTests` asserts the
/// directory is gone the moment `remove` returns), which the #50 / #57 / #80 hardening
/// relies on; making that path async to accommodate an async shutdown would have
/// loosened a guarantee those tests deliberately pin.
public enum AccountRemoval {

    /// Run the two steps in order and report whether the registry removal succeeded.
    ///
    /// The gateway is stopped even when the removal then fails (a rolled-back
    /// persist). That is the deliberate trade: a stopped gateway is recoverable —
    /// the next `acquire` starts a fresh one — whereas reaping a directory out from
    /// under a live writer is not.
    /// `@MainActor` because both steps are: `AccountManager` is main-actor isolated,
    /// and the caller is a SwiftUI action. Keeping the whole sequence on the main
    /// actor means neither closure crosses an isolation boundary — only the inner
    /// `await` on the pool actor hops off and back.
    @MainActor
    public static func perform(
        accountID: String,
        stopGateway: (String) async -> Void,
        removeFromRegistry: (String) -> Bool
    ) async -> Bool {
        await stopGateway(accountID)
        return removeFromRegistry(accountID)
    }
}
