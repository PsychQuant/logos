import Testing
import Foundation
import LogoSwitch

/// Truth table for the single-decision reducer (#34, bug #3). The load-bearing
/// case is "both signals in one chunk → OAuth wins" — the regression the old
/// sequential clear-then-force code could not guarantee.
@Suite("AuthCoordinator")
struct AuthCoordinatorTests {

    private let url = URL(string: "https://claude.com/cai/oauth/authorize?x=1")!

    @Test("no signals → none")
    func noSignals() {
        #expect(AuthCoordinator.decide(AuthSignals(oauthURL: nil, live401: false)) == .none)
    }

    @Test("OAuth only → reauthInProgress(url)")
    func oauthOnly() {
        #expect(AuthCoordinator.decide(AuthSignals(oauthURL: url, live401: false)) == .reauthInProgress(url))
    }

    @Test("401 only → needsReauth")
    func live401Only() {
        #expect(AuthCoordinator.decide(AuthSignals(oauthURL: nil, live401: true)) == .needsReauth)
    }

    @Test("both in the same chunk → OAuth wins (no flip-flop, bug #3)")
    func bothSameChunkOAuthWins() {
        let decision = AuthCoordinator.decide(AuthSignals(oauthURL: url, live401: true))
        #expect(decision == .reauthInProgress(url))
        // Explicitly NOT .needsReauth — the chunk must not clear-then-re-force.
        #expect(decision != .needsReauth)
    }
}
