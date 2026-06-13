import Foundation

/// The two auth signals a single PTY chunk can carry (PsychQuant/logos#30/#31).
/// `oauthURL` = a re-auth was just INITIATED (the authorize URL appeared);
/// `live401` = the hosted claude reported it's unauthenticated this chunk.
public struct AuthSignals: Sendable, Equatable {
    public let oauthURL: URL?
    public let live401: Bool
    public init(oauthURL: URL?, live401: Bool) {
        self.oauthURL = oauthURL
        self.live401 = live401
    }
}

/// The single auth outcome for a chunk.
public enum AuthDecision: Sendable, Equatable {
    /// Nothing happened this chunk.
    case none
    /// Re-auth initiated: open `URL`, clear the banner + un-force the switcher.
    case reauthInProgress(URL)
    /// Unauthenticated: surface the banner + force the active account's re-auth.
    case needsReauth
}

/// Pure reducer that collapses the two passive-detector signals into ONE decision
/// per chunk, fixing the order-dependent flip-flop (#34, bug #3): the old
/// `handleChunk` ran the OAuth-clear block then the 401-force block sequentially
/// against the same rolling buffer, so a chunk holding BOTH could clear then
/// immediately re-force, leaving the banner/switcher incoherent.
///
/// Invariant: OAuth-initiated **strictly wins** within a chunk — a re-auth that
/// just started supersedes a stale 401 still resident in the buffer, so a chunk
/// can never both clear and re-force. The app applies exactly one `AuthDecision`.
public enum AuthCoordinator {
    public static func decide(_ signals: AuthSignals) -> AuthDecision {
        if let url = signals.oauthURL {
            return .reauthInProgress(url)
        }
        if signals.live401 {
            return .needsReauth
        }
        return .none
    }
}
