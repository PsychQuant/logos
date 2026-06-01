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

    /// Whether the unauthenticated signal was present on the PREVIOUS scan, so
    /// `detect` fires only on the `absent → present` rising edge (#30 Item 2a).
    /// This replaces the old one-shot `fired` latch: it still won't storm while
    /// the signal sits in the (rolling) buffer, but a genuinely NEW 401 — after
    /// the previous one scrolled out — re-fires.
    ///
    /// Dismiss interaction (#30 verify, codex P3 / DA1): the detector keeps NO
    /// memory of a banner dismiss — dismissing only clears the UI flag and never
    /// touches `wasPresent`, so no detector⇄state plumbing is needed. The flip
    /// side: a dismiss is NOT sticky-for-session. Once the dismissed 401 scrolls
    /// out of the rolling buffer and a fresh 401 arrives, the rising edge fires
    /// again and the banner re-surfaces. That is intended (a still-unauthenticated
    /// session should keep nudging) and `markNeedsAuth` is idempotent, so it
    /// can't storm — but it does mean the banner can reappear after a dismiss.
    private var wasPresent = false

    public init() {}

    /// The unauthenticated signal. Tightened in #29 verify to require the auth
    /// ERROR marker, not the bare recovery phrase — `Please run /login` alone
    /// false-fires when the user types it or claude merely quotes it, so it must
    /// co-occur with `401`. `Invalid authentication credentials` is the verbatim
    /// 401 body (a user is very unlikely to type it) so it stands alone. Mirrors
    /// `OAuthURLDetector`'s "match only the real thing" discipline.
    private static func isUnauthenticated(_ buffer: String) -> Bool {
        if buffer.contains("Invalid authentication credentials") { return true }
        if buffer.contains("Please run /login") && buffer.contains("401") { return true }
        return false
    }

    /// Returns true on the rising edge — the scan where the unauthenticated
    /// signal newly appears in the (ANSI-stripped) buffer. Stays false while the
    /// signal remains present (no storm), and re-arms once it leaves the buffer.
    public mutating func detect(in buffer: String) -> Bool {
        let present = Self.isUnauthenticated(buffer)
        defer { wasPresent = present }
        return present && !wasPresent
    }
}
