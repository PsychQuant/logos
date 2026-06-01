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
/// SECURITY: this is locked to the claude authorize URL (`claude.com` +
/// `/cai/oauth/authorize`). It must NEVER become a general "open any URL printed
/// to the terminal" — that would let any subprocess output open arbitrary URLs.
@MainActor
public struct OAuthURLDetector {

    /// Contiguous start token (host + path are not wrapped by the terminal, only
    /// the long query string is). Used to locate a candidate.
    private static let startToken = "https://claude.com/cai/oauth/authorize?"
    private static let requiredHost = "claude.com"
    private static let requiredPath = "/cai/oauth/authorize"

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
        // Scan EVERY authorize-URL token in the buffer, not just the first
        // (#30 verify, codex P2). With the reset-immune `RollingTerminalBuffer`
        // (#30) an already-`seen` URL lingers in the scan window, so returning
        // `nil` on the first (stale) token would SHADOW a genuinely new URL that
        // appears later in the same buffer — e.g. a failed login that re-prompts.
        // Return the first token that reassembles to a valid, not-yet-seen URL;
        // advance past stale/invalid tokens and keep looking.
        var searchStart = buffer.startIndex
        while let startRange = buffer.range(of: Self.startToken,
                                            range: searchStart..<buffer.endIndex) {
            let reassembled = Self.reassembleURL(in: buffer, from: startRange.lowerBound)
            // `&&` short-circuits, so `seen.insert` only runs for a structurally
            // valid authorize URL — invalid candidates never pollute `seen`. An
            // already-seen URL yields `inserted == false` → fall through to the
            // next token (preserving "open each distinct URL once").
            if let url = URL(string: reassembled),
               url.host == Self.requiredHost,
               url.path == Self.requiredPath,
               seen.insert(reassembled).inserted {
                return url
            }
            searchStart = startRange.upperBound
        }
        return nil
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
