import Testing
import Foundation
@testable import Logos

/// #111: the census is the ONLY answer to "which accounts are windows actually using".
///
/// The chip used to read `AccountManager.activeAccountId`, which #42 demoted to a
/// new-window seed that an in-window switch never writes — so it could never move.
/// These tests assert the census's counts DIRECTLY rather than through the UI: a
/// miscount renders as a perfectly normal-looking chip, so the UI cannot be the
/// detector (#111 diagnosis, Risk 3).
@Suite("AccountWindowCensus", .serialized)
@MainActor
struct AccountWindowCensusTests {

    @Test("an empty census reports no windows for any account")
    func empty() {
        let census = AccountWindowCensus()
        #expect(census.windowCount(for: "acct-a") == 0)
        #expect(census.activeAccountIds.isEmpty)
    }

    @Test("registering one window counts one")
    func registerOne() {
        let census = AccountWindowCensus()
        census.setAccount("acct-a", forWindow: UUID())
        #expect(census.windowCount(for: "acct-a") == 1)
    }

    /// The multi-chip display (`使用中 ×2`) is exactly this number, so two windows on
    /// one account must count two — not collapse to a boolean.
    @Test("two windows on the same account count two")
    func twoWindowsSameAccount() {
        let census = AccountWindowCensus()
        census.setAccount("acct-a", forWindow: UUID())
        census.setAccount("acct-a", forWindow: UUID())
        #expect(census.windowCount(for: "acct-a") == 2)
    }

    /// #111 Risk 2: `onAppear` can re-enter on macOS. Keying by a per-window token
    /// (not by accountId) makes a repeat registration idempotent — otherwise a single
    /// window would inflate its own account's count on every re-appear.
    @Test("re-registering the SAME window token is idempotent")
    func reRegisterIsIdempotent() {
        let census = AccountWindowCensus()
        let token = UUID()
        census.setAccount("acct-a", forWindow: token)
        census.setAccount("acct-a", forWindow: token)
        census.setAccount("acct-a", forWindow: token)
        #expect(census.windowCount(for: "acct-a") == 1)
    }

    /// Switching accounts inside a window is a MOVE, not an add — the old account must
    /// drop to zero in the same step. This is the exact motion the bug report describes
    /// ("切換之後 chip 不會跟著移動").
    @Test("switching a window's account moves the count, leaving nothing behind")
    func switchMovesTheCount() {
        let census = AccountWindowCensus()
        let token = UUID()
        census.setAccount("acct-a", forWindow: token)
        census.setAccount("acct-b", forWindow: token)
        #expect(census.windowCount(for: "acct-a") == 0)
        #expect(census.windowCount(for: "acct-b") == 1)
    }

    @Test("removing a window drops its account's count")
    func removeDropsCount() {
        let census = AccountWindowCensus()
        let token = UUID()
        census.setAccount("acct-a", forWindow: token)
        census.removeWindow(token)
        #expect(census.windowCount(for: "acct-a") == 0)
    }

    /// #111 Risk 1 (phantom chip): the deregistration path is the correctness-critical
    /// one — a leak here strands an account permanently labelled 使用中. Removing one of
    /// two windows must leave the other counted, and removing an unknown token must be a
    /// no-op rather than corrupting the count (the `isolated deinit` backstop can fire
    /// after an explicit `onDisappear` already removed the same token).
    @Test("removing one of two windows leaves the other counted")
    func removeOneOfTwo() {
        let census = AccountWindowCensus()
        let first = UUID()
        let second = UUID()
        census.setAccount("acct-a", forWindow: first)
        census.setAccount("acct-a", forWindow: second)
        census.removeWindow(first)
        #expect(census.windowCount(for: "acct-a") == 1)
    }

    @Test("removing an unknown or already-removed token is a harmless no-op")
    func removeUnknownIsNoOp() {
        let census = AccountWindowCensus()
        let token = UUID()
        census.setAccount("acct-a", forWindow: token)
        census.removeWindow(token)
        census.removeWindow(token)          // double-remove: onDisappear then deinit
        census.removeWindow(UUID())         // never-registered token
        #expect(census.windowCount(for: "acct-a") == 0)
    }

    /// A window with no account yet (`WindowAccountSelection.accountId` is nil until
    /// `WindowRoot` seeds it) must not be counted against anything — and passing nil
    /// later must clear a previously-registered account rather than stranding it.
    @Test("a nil account registers nothing and clears a prior registration")
    func nilAccountClears() {
        let census = AccountWindowCensus()
        let token = UUID()
        census.setAccount(nil, forWindow: token)
        #expect(census.activeAccountIds.isEmpty)

        census.setAccount("acct-a", forWindow: token)
        #expect(census.windowCount(for: "acct-a") == 1)

        census.setAccount(nil, forWindow: token)
        #expect(census.windowCount(for: "acct-a") == 0)
    }

    /// A usage row's `registryAccountId` is optional, so the query takes an optional. A row
    /// with no registry id cannot be open in any window — 0 is the answer, not a crash and
    /// not an accidental match against some other row.
    @Test("querying a nil account id counts zero, never matching a registered window")
    func queryNilCountsZero() {
        let census = AccountWindowCensus()
        census.setAccount("acct-a", forWindow: UUID())
        #expect(census.windowCount(for: nil) == 0)
        #expect(census.windowCount(for: "acct-a") == 1)
    }

    @Test("activeAccountIds reports every account with at least one window")
    func activeIds() {
        let census = AccountWindowCensus()
        census.setAccount("acct-a", forWindow: UUID())
        census.setAccount("acct-a", forWindow: UUID())
        census.setAccount("acct-b", forWindow: UUID())
        #expect(census.activeAccountIds == ["acct-a", "acct-b"])
    }
}
