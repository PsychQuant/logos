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
        guard let startRange = buffer.range(of: Self.startToken) else { return nil }

        // Accumulate URL-valid characters from the start of the token. Single
        // whitespace runs (terminal wrap artifacts) are skipped; a blank line
        // (>= 2 newlines) is the structural end-of-URL boundary — stopping there
        // avoids swallowing the following "Paste code here >" prompt, whose
        // letters are themselves URL-valid characters.
        var reassembled = ""
        var pendingNewlines = 0
        var idx = startRange.lowerBound
        while idx < buffer.endIndex {
            let ch = buffer[idx]
            if ch == "\n" || ch == "\r" {
                pendingNewlines += 1
                if pendingNewlines >= 2 { break }   // blank line → URL ended
            } else if ch.isWhitespace {
                // spaces / tabs: wrap padding — skip without ending the URL
            } else if Self.urlChars.contains(ch) {
                pendingNewlines = 0
                reassembled.append(ch)
            } else {
                break   // a real non-URL, non-whitespace boundary
            }
            idx = buffer.index(after: idx)
        }

        guard let url = URL(string: reassembled),
              url.host == Self.requiredHost,
              url.path == Self.requiredPath else { return nil }
        guard seen.insert(reassembled).inserted else { return nil }
        return url
    }
}
