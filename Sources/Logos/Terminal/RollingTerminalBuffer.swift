import Foundation

/// A bounded, reset-immune view of recent terminal output for the passive
/// detectors (PsychQuant/logos#30 Item 1).
///
/// The auto-handle `PatternParser` is `reset()` whenever a rule fires (see
/// `SwiftTermView.Coordinator.handleChunk`), which can drop the first half of a
/// signal that spans two PTY chunks when a reset lands between them — so a 401
/// (`LoginPromptDetector`, #29) or the OAuth authorize URL (`OAuthURLDetector`,
/// #17) could be missed. Both passive detectors scan THIS buffer instead, which
/// the auto-handle path never resets, so an interleaved reset no longer hides a
/// split signal.
///
/// It holds the last `capacity` **raw** characters and exposes them
/// ANSI-stripped on read. Storing raw (rather than pre-stripping each chunk)
/// means an ANSI escape that spans a chunk *boundary* is stripped correctly —
/// the strip sees the whole tail at once, exactly as `PatternParser` does —
/// instead of leaving a partial escape sequence behind.
///
/// Caveat (harmless): the `capacity` front-truncation can drop the leading
/// `ESC` of an escape sequence whose tail survives (e.g. `[0m` with no `\x1B`),
/// which `stripAnsi` then can't strip. This is benign — that orphaned junk sits
/// at the *front* of the window, while the detectors match their signals (the
/// short 401 line / the authorize URL) near the freshest *tail*, and a partial
/// escape can't spell any matched substring.
@MainActor
public struct RollingTerminalBuffer {

    /// Window size in raw characters. 8192 ≫ the ~400-char OAuth authorize URL
    /// and ≫ the short 401 line, so neither signal can be split out of the
    /// window between two adjacent chunks.
    public static let capacity = 8192

    private var raw = ""
    /// Cached ANSI-stripped view, recomputed once per `append` so the two
    /// detectors that read `contents` each chunk don't re-strip 8 KB twice.
    private var stripped = ""

    public init() {}

    /// Append a raw PTY chunk, keep only the last `capacity` raw chars, and
    /// recompute the ANSI-stripped view. Never reset by the auto-handle path.
    public mutating func append(_ chunk: String) {
        raw += chunk
        if raw.count > Self.capacity {
            raw.removeFirst(raw.count - Self.capacity)
        }
        stripped = PatternParser.stripAnsi(raw)
    }

    /// The ANSI-stripped contents of the window, for the passive detectors to scan.
    public var contents: String { stripped }
}
