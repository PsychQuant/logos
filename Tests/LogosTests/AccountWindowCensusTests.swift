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
        #expect(census.windowCount(for: "acct-a") == 0)

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

}

/// #111 verify (codex HIGH + logic MEDIUM + regression MEDIUM + devil's advocate): the
/// round-1 tests asserted only the census's own dictionary, so **the entire
/// `WindowCensusTicket` — including the `isolated deinit` teardown backstop — could have
/// been deleted with all of them still green**. That is exactly where the round-1
/// lifecycle defect hid. These exercise the ticket itself.
@Suite("WindowCensusTicket lifecycle", .serialized)
@MainActor
struct WindowCensusTicketTests {

    /// THE round-1 HIGH. `appear` and `move` used to be one `bind` method with no phase,
    /// so a change arriving after `release()` silently re-registered a closed window and
    /// stranded its account permanently labelled 使用中.
    ///
    /// This is not a theoretical ordering worry: `WindowRoot` has a second
    /// `onChange(of: accountManager.accounts)` that rewrites `selection.accountId` to
    /// re-seed a window off a deleted account, which cascades into the selection
    /// `onChange` — so *another window deleting an account* was enough to trigger it.
    @Test("a move arriving after release must NOT resurrect the entry")
    func lateMoveAfterReleaseIsInert() {
        let census = AccountWindowCensus()
        let ticket = WindowCensusTicket()

        ticket.appear(in: census, accountId: "acct-a")
        #expect(census.windowCount(for: "acct-a") == 1)

        ticket.release()
        #expect(census.windowCount(for: "acct-a") == 0)

        ticket.move(to: "acct-b", in: census)           // the reseed cascade
        #expect(census.windowCount(for: "acct-b") == 0, "released ticket re-registered")
        #expect(census.windowCount(for: "acct-a") == 0)
    }

    /// The other direction, which no lens except the devil's advocate raised: the
    /// two-layer teardown only guards OVER-counting. Guarding `move` behind a plain
    /// "already registered" flag would have traded that for UNDER-counting — a window
    /// whose `onAppear` never landed could then never be counted, and unlike an
    /// over-count nothing later corrects it. `pending` self-heals forward.
    /// Round 2 shipped this test asserting `== 0` on the first move — i.e. asserting the
    /// ABSENCE of the self-heal it was named for, because `move` could only reach a census
    /// that `appear` had stored. Five round-2 lenses caught it. `move` now takes the
    /// census, so the name and the assertion finally agree.
    @Test("a move before any appear registers on its own, so a missed onAppear self-heals")
    func moveBeforeAppearSelfHeals() {
        let census = AccountWindowCensus()
        let ticket = WindowCensusTicket()

        ticket.move(to: "acct-a", in: census)
        #expect(census.windowCount(for: "acct-a") == 1, "pending move did not self-heal")

        ticket.move(to: "acct-b", in: census)
        #expect(census.windowCount(for: "acct-a") == 0)
        #expect(census.windowCount(for: "acct-b") == 1)
    }

    /// The `.released` half, stated separately from the `.pending` half so a future
    /// mutation that guts one is not masked by the other. Deleting the phase enum turns
    /// THIS red — which is how the round-2 claim that the whole machine was inert
    /// ("delete Phase, 17/17 still green") was refuted.
    @Test("a released ticket stays released even when the move supplies a census")
    func releasedIgnoresMoveEvenWithCensus() {
        let census = AccountWindowCensus()
        let ticket = WindowCensusTicket()
        ticket.appear(in: census, accountId: "acct-a")
        ticket.release()
        ticket.move(to: "acct-b", in: census)
        #expect(census.windowCount(for: "acct-b") == 0)
    }

    /// A genuine re-appear after release MUST re-register — the window came back. Three
    /// round-2 lenses proposed guarding `appear` against `.released`; the devil's advocate
    /// refuted them, because that guard turns every disappear/reappear cycle into a
    /// permanent under-count. This pins the behaviour so the "fix" cannot be applied later.
    @Test("a genuine re-appear after release re-registers rather than staying torn down")
    func reAppearAfterReleaseReRegisters() {
        let census = AccountWindowCensus()
        let ticket = WindowCensusTicket()
        ticket.appear(in: census, accountId: "acct-a")
        ticket.release()
        #expect(census.windowCount(for: "acct-a") == 0)

        ticket.appear(in: census, accountId: "acct-a")
        #expect(census.windowCount(for: "acct-a") == 1, "a returning window lost its mark")
    }

    /// The teardown backstop itself — the thing round 1 documented but never executed.
    /// Dropping the last reference must clear the entry even though `release()` was
    /// never called, which is the missed-`onDisappear` case #91 hit with FSEventStream.
    @Test("dropping the ticket without release still clears its entry (isolated deinit)")
    func deinitIsTheBackstop() {
        let census = AccountWindowCensus()
        do {
            let ticket = WindowCensusTicket()
            ticket.appear(in: census, accountId: "acct-a")
            #expect(census.windowCount(for: "acct-a") == 1)
        }   // no release() — only ARC dropping the ticket
        #expect(census.windowCount(for: "acct-a") == 0, "isolated deinit did not deregister")
    }

    /// Both layers firing must be harmless — that is why `removeWindow` is idempotent.
    @Test("release followed by deinit does not double-decrement a sibling window")
    func releaseThenDeinitLeavesSiblingIntact() {
        let census = AccountWindowCensus()
        let survivor = WindowCensusTicket()
        survivor.appear(in: census, accountId: "acct-a")
        do {
            let closing = WindowCensusTicket()
            closing.appear(in: census, accountId: "acct-a")
            #expect(census.windowCount(for: "acct-a") == 2)
            closing.release()                            // prompt path
        }                                                // then deinit, same token
        #expect(census.windowCount(for: "acct-a") == 1, "sibling window lost its mark")
    }

    /// A re-entrant `onAppear` is the reason the token is per-window rather than
    /// per-account — re-appearing must re-register, never add a second entry.
    @Test("re-appearing does not double-count, and moves when the account changed")
    func reAppearIsIdempotent() {
        let census = AccountWindowCensus()
        let ticket = WindowCensusTicket()
        ticket.appear(in: census, accountId: "acct-a")
        ticket.appear(in: census, accountId: "acct-a")
        #expect(census.windowCount(for: "acct-a") == 1)

        ticket.appear(in: census, accountId: "acct-b")
        #expect(census.windowCount(for: "acct-a") == 0)
        #expect(census.windowCount(for: "acct-b") == 1)
    }

    /// Re-appearing against a DIFFERENT census must not leave an orphan in the old one.
    @Test("re-appearing in another census drops the entry in the previous one")
    func appearInDifferentCensusDropsTheOld() {
        let first = AccountWindowCensus()
        let second = AccountWindowCensus()
        let ticket = WindowCensusTicket()

        ticket.appear(in: first, accountId: "acct-a")
        ticket.appear(in: second, accountId: "acct-a")
        #expect(first.windowCount(for: "acct-a") == 0, "orphan left in the previous census")
        #expect(second.windowCount(for: "acct-a") == 1)
    }

    /// Two live windows on one account is the case the whole `Int` exists for — the
    /// `使用中 ×2` the ruling asked for.
    @Test("two tickets on one account count two, and releasing one leaves one")
    func twoTicketsOneAccount() {
        let census = AccountWindowCensus()
        let a = WindowCensusTicket()
        let b = WindowCensusTicket()
        a.appear(in: census, accountId: "acct-a")
        b.appear(in: census, accountId: "acct-a")
        #expect(census.windowCount(for: "acct-a") == 2)
        a.release()
        #expect(census.windowCount(for: "acct-a") == 1)
    }
}
