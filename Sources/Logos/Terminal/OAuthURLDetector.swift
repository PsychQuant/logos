import Foundation

/// Detects the claude OAuth authorize URL in (ANSI-stripped) terminal output and
/// yields it once, so Logos can open it natively (PsychQuant/logos#17).
///
/// Why this exists: claude opens the login browser via the npm `open` package,
/// which spawns the macOS `open` command. Inside Logos the spawned claude
/// inherits the app's launchd/GUI-session environment, and that detached `open`
/// child does not foreground a browser — so the user is left to copy a ~400-char
/// URL by hand. Logos detects that URL in its existing PTY stream-tee and opens
/// it via `NSWorkspace`.
///
/// SECURITY: this is locked to the enumerated claude authorize forms — Claude.ai
/// (`claude.com` + `/cai/oauth/authorize`) and Anthropic Console
/// (`platform.claude.com` + `/oauth/authorize`) — each reassembled URL validated
/// against ITS OWN host + path, matched exactly (never a wildcard or host-suffix).
/// It must NEVER become a general "open any URL printed to the terminal" — that
/// would let any subprocess output open arbitrary URLs (#17, #35).
@MainActor
public struct OAuthURLDetector {

    /// One enumerated claude authorize form. `startToken` is the contiguous prefix
    /// used to locate a candidate (host + path are not wrapped by the terminal,
    /// only the long query string is); `host` + `path` are the exact values the
    /// reassembled URL must match. Each candidate is validated against its OWN
    /// form's pair — never a shared or looser check — so the allowlist cannot be
    /// broadened into the arbitrary-URL hole #17 guards.
    private struct Form {
        let startToken: String
        let host: String
        let path: String
    }

    /// The complete authorize allowlist (#35). Installed claude ships BOTH forms
    /// in one OAuth-config struct: Claude.ai (subscription) and Anthropic Console
    /// (API). Exactly these two fully-qualified (host, path) pairs are matched —
    /// no wildcard, no host-suffix. Adding a form here is the only way to broaden
    /// it; drift across claude versions is why this detector stays "interim".
    private static let forms: [Form] = [
        Form(startToken: "https://claude.com/cai/oauth/authorize?",
             host: "claude.com", path: "/cai/oauth/authorize"),
        Form(startToken: "https://platform.claude.com/oauth/authorize?",
             host: "platform.claude.com", path: "/oauth/authorize"),
    ]

    /// RFC 3986 URL characters (unreserved + reserved + percent). Whitespace is
    /// deliberately excluded — it is skipped while accumulating so a URL the
    /// terminal wrapped across lines is reassembled.
    private static let urlChars: Set<Character> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    /// URLs already yielded, so re-scanning the accumulating PTY buffer on each
    /// chunk does not re-open the same URL.
    private var seen: Set<String> = []

    public init() {}

    /// Scan an ANSI-stripped buffer for the claude authorize URL. Returns it the
    /// first time it appears (reassembling across terminal wrapping); `nil`
    /// otherwise. Idempotent per distinct URL.
    public mutating func detect(in buffer: String) -> URL? {
        // Scan EVERY authorize-URL token across BOTH forms, not just the first
        // (#30 verify, codex P2), in buffer order. With the reset-immune
        // `RollingTerminalBuffer` (#30) an already-`seen` URL lingers in the scan
        // window, so returning `nil` on the first (stale) token would SHADOW a
        // genuinely new URL later in the same buffer — e.g. a failed login that
        // re-prompts, possibly with the OTHER form. Return the first token that
        // reassembles to a valid, not-yet-seen URL; advance past stale/invalid
        // tokens and keep looking.
        var searchStart = buffer.startIndex
        while let match = Self.nextFormToken(in: buffer, from: searchStart) {
            let reassembled = Self.reassembleURL(in: buffer, from: match.range.lowerBound)
            // `&&` short-circuits, so `seen.insert` only runs for a URL that
            // matches its OWN form's host + path — invalid candidates never
            // pollute `seen`. An already-seen URL yields `inserted == false` →
            // fall through to the next token (preserving "open each distinct URL
            // once").
            if let url = URL(string: reassembled),
               url.host == match.form.host,
               url.path == match.form.path,
               seen.insert(reassembled).inserted {
                return url
            }
            searchStart = match.range.upperBound
        }
        return nil
    }

    /// The earliest authorize-token occurrence at/after `from` across ALL forms,
    /// with the form it belongs to — or `nil` when none remains. Choosing by
    /// earliest buffer position (not by form order) preserves the single-form
    /// "first-unseen-URL-in-buffer-order wins" property (#30) now that two forms'
    /// tokens can interleave in one buffer.
    private static func nextFormToken(in buffer: String,
                                      from: String.Index) -> (form: Form, range: Range<String.Index>)? {
        var earliest: (form: Form, range: Range<String.Index>)?
        for form in forms {
            guard let range = buffer.range(of: form.startToken,
                                           range: from..<buffer.endIndex) else { continue }
            if let current = earliest, current.range.lowerBound <= range.lowerBound { continue }
            earliest = (form, range)
        }
        return earliest
    }

    /// Reassemble a candidate URL string starting at `start`, skipping terminal
    /// wrap whitespace and stopping at the structural blank-line boundary.
    ///
    /// The terminal hard-wraps the long URL with `\r\r\n` (CR CR LF) every ~78
    /// columns, so only the LINE FEED (`\n`) counts as a line break — a single
    /// `\n` is a wrap (skip), a blank line (>= 2 `\n`) is the structural
    /// end-of-URL boundary. `\r`, spaces and tabs are wrap padding and are
    /// skipped without ending the URL. Counting `\r` toward the boundary would
    /// truncate the URL at the first wrap (the two `\r`s in `\r\r\n` alone
    /// reach the >= 2 threshold). Stopping at the blank line avoids swallowing
    /// the following "Paste code here >" prompt, whose letters are themselves
    /// URL-valid characters (and whose spaces the terminal renders as cursor
    /// moves, so they vanish after ANSI stripping).
    private static func reassembleURL(in buffer: String, from start: String.Index) -> String {
        var reassembled = ""
        var pendingLineFeeds = 0
        var idx = start
        while idx < buffer.endIndex {
            let ch = buffer[idx]
            // NOTE: Swift clusters CR+LF into one `Character` ("\r\n"), so the
            // real `\r\r\n` wrap iterates as a lone `\r` then the `\r\n` grapheme
            // — both must be recognised as a line feed here.
            if ch == "\n" || ch == "\r\n" {
                pendingLineFeeds += 1
                if pendingLineFeeds >= 2 { break }   // blank line → URL ended
            } else if ch.isWhitespace {
                // lone \r, spaces, tabs: wrap padding — skip without ending the URL
            } else if Self.urlChars.contains(ch) {
                pendingLineFeeds = 0
                reassembled.append(ch)
            } else {
                break   // a real non-URL, non-whitespace boundary
            }
            idx = buffer.index(after: idx)
        }
        return reassembled
    }
}
