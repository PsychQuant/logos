import Foundation

/// Detects the genuine claude "unauthenticated" signal in (ANSI-stripped) terminal
/// output, so Logos can surface a passive re-auth banner (PsychQuant/logos#29).
///
/// PASSIVE + FIRST-PARTY-SAFE: this only READS output to flip a UI flag. It never
/// touches the OAuth token, never injects `/login`, never proxies the callback —
/// the genuine `claude` owns the entire auth lifecycle (and `OAuthURLDetector`
/// opens the browser). Logos stays a transparent host of the first-party CLI, not
/// a third-party auth client.
///
/// Scoped to claude's literal auth-error strings (mirrors `OAuthURLDetector`'s
/// locked-URL discipline — it must NEVER become a general "any error → banner").
@MainActor
public struct LoginPromptDetector {

    /// claude's literal recovery instruction + the 401 body. Matching either is
    /// the unauthenticated signal. Kept tight so a healthy session is never nagged.
    private static let signals = [
        "Please run /login",
        "Invalid authentication credentials",
    ]

    /// Latches once per detector instance so re-scanning the growing PTY buffer
    /// doesn't re-fire. A restart recreates the terminal view (+ this detector)
    /// with a fresh generation id (#18), so a new session re-detects naturally.
    private var fired = false

    public init() {}

    /// Returns true the FIRST time the unauthenticated signal appears in the
    /// (ANSI-stripped) buffer; false otherwise. Idempotent per instance.
    public mutating func detect(in buffer: String) -> Bool {
        guard !fired else { return false }
        guard Self.signals.contains(where: { buffer.contains($0) }) else { return false }
        fired = true
        return true
    }
}
