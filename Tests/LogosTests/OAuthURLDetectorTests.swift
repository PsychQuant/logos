import Testing
import Foundation
@testable import Logos

/// Tests for the claude OAuth authorize-URL detector (PsychQuant/logos#17, #35).
/// The detector scans ANSI-stripped terminal output for a claude login URL so
/// Logos can open it natively (claude's own browser-open fails inside Logos's
/// spawned-PTY launchd context). SECURITY: it must match ONLY the enumerated
/// claude authorize forms — never a general URL opener (#17).
///
/// #35: installed claude ships TWO authorize forms in one OAuth-config struct —
/// `https://claude.com/cai/oauth/authorize` (Claude.ai / subscription) and
/// `https://platform.claude.com/oauth/authorize` (Anthropic Console / API). The
/// single-form detector fired only on the first; the Console form fell through,
/// forcing a hand-copy of the ~400-char CRLF-wrapped URL that truncates the tail
/// where `redirect_uri` lives → claude rejects it ("Missing redirect_uri").
@Suite("OAuthURLDetector", .serialized)
@MainActor
struct OAuthURLDetectorTests {

    /// Realistic Claude.ai (subscription) authorize URL. `redirect_uri` sits in the
    /// TAIL — exactly the param a hand-copy of the wrapped URL truncates (#35).
    private let claudeAiURL =
        "https://claude.com/cai/oauth/authorize?code=true" +
        "&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code" +
        "&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback" +
        "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference" +
        "&code_challenge=SQtfq9eMXwJ0ezSJhh2_SlWgHzOV3JzNEUv5An0Zr78&code_challenge_method=S256" +
        "&state=JXzYippVmAHWmvV__aN12VaUPRwT3JC050DRE9xnnGQ"

    /// Realistic Anthropic Console (API) authorize URL — host `platform.claude.com`,
    /// path `/oauth/authorize`. The form today's single-form detector never fires
    /// on (RED before #35), which forced the truncating hand-copy.
    private let consoleURL =
        "https://platform.claude.com/oauth/authorize?code=true" +
        "&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code" +
        "&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback" +
        "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference" +
        "&code_challenge=SQtfq9eMXwJ0ezSJhh2_SlWgHzOV3JzNEUv5An0Zr78&code_challenge_method=S256" +
        "&state=JXzYippVmAHWmvV__aN12VaUPRwT3JC050DRE9xnnGQ"

    /// Simulate the terminal hard-wrapping a long URL with `\r\r\n` (CR CR LF) every
    /// `width` columns — the exact wrap `reassembleURL` must stitch back (#17/#30).
    private func hardWrap(_ url: String, every width: Int) -> String {
        var out = ""
        var col = 0
        for ch in url {
            out.append(ch)
            col += 1
            if col == width { out += "\r\r\n"; col = 0 }
        }
        return out
    }

    // MARK: - Both forms detected

    @Test("finds the Claude.ai authorize URL in surrounding output")
    func detectFindsClaudeAiURL() {
        var detector = OAuthURLDetector()
        let buffer = """
        Browser didn't open? Use the url below to sign in (c to copy)

        \(claudeAiURL)

        Paste code here if prompted >
        """
        #expect(detector.detect(in: buffer)?.absoluteString == claudeAiURL)
    }

    @Test("finds the Anthropic Console authorize URL (the #35 second form)")
    func detectFindsConsoleURL() {
        var detector = OAuthURLDetector()
        let buffer = """
        Browser didn't open? Use the url below to sign in (c to copy)

        \(consoleURL)

        Paste code here if prompted >
        """
        #expect(detector.detect(in: buffer)?.absoluteString == consoleURL)
    }

    // MARK: - Reassembly keeps the redirect_uri tail (the #35 regression)

    @Test("reassembles the CRLF-wrapped Claude.ai URL with redirect_uri intact")
    func detectReassemblesWrappedClaudeAiURL() {
        var detector = OAuthURLDetector()
        let wrapped = "rl below to sign in (c to copy)\r\r\n\r\r\n"
            + hardWrap(claudeAiURL, every: 78)
            + "\r\r\n\r\r\nPastecodehereifprompted>"
        let url = detector.detect(in: wrapped)
        #expect(url?.absoluteString == claudeAiURL)
        #expect(url?.query?.contains("redirect_uri") == true)
    }

    @Test("reassembles the CRLF-wrapped Console URL with redirect_uri intact")
    func detectReassemblesWrappedConsoleURL() {
        var detector = OAuthURLDetector()
        let wrapped = "rl below to sign in (c to copy)\r\r\n\r\r\n"
            + hardWrap(consoleURL, every: 78)
            + "\r\r\n\r\r\nPastecodehereifprompted>"
        let url = detector.detect(in: wrapped)
        #expect(url?.absoluteString == consoleURL)
        #expect(url?.query?.contains("redirect_uri") == true)
    }

    // MARK: - Reassembly ends at a bare newline, not only a blank line (#82)

    @Test("ends the reassembled URL at a bare newline, not splicing the next line (#82)")
    func detectEndsAtBareNewlineNotSplice() {
        var detector = OAuthURLDetector()
        // A single `\n` (NOT the terminal's `\r\r\n` hard-wrap) separates the
        // authorize URL from URL-valid content on the very next line. Today's
        // reassembler treats any lone `\n` as wrap-continuation, so it swallows
        // the newline and splices the trailing token onto the query string. The
        // URL must instead END at the bare newline — `token=SECRET123` is trailing
        // content, not part of the URL.
        let authorizeURL = "https://claude.com/cai/oauth/authorize?code=true&state=x"
        let buffer = "\(authorizeURL)\ntoken=SECRET123\n\nPaste code here if prompted >"
        let url = detector.detect(in: buffer)
        #expect(url?.absoluteString == authorizeURL)
        #expect(url?.query?.contains("token=SECRET123") == false)
    }

    @Test("a genuine \\r\\r\\n wrap still stitches while a bare \\n ends the URL (#82)")
    func detectStitchesWrapButEndsAtBareNewline() {
        var detector = OAuthURLDetector()
        // The terminal's hard-wrap is `\r\r\n` (CR CR LF): its LF grapheme is
        // preceded by a lone `\r`, so it is stitched (continuation). A bare `\n`
        // has no preceding `\r`, so it ends the URL. One buffer exercises both.
        let head = "https://claude.com/cai/oauth/authorize?code=true&state="
        let wrapped = head + "\r\r\n" + "abcXYZ"   // one genuine mid-query wrap
        let url = detector.detect(in: wrapped + "\ntrailing=nope\n\n")
        #expect(url?.absoluteString == head + "abcXYZ")
        #expect(url?.query?.contains("trailing") == false)
    }

    // MARK: - Security: host + path stay locked (#17)

    @Test("ignores claude.com authorize WITHOUT the /cai/ path (path lock, security)")
    func detectIgnoresClaudeComWithoutCai() {
        var detector = OAuthURLDetector()
        // Same host as the Claude.ai form but the console path — must NOT be
        // treated as either enumerated form.
        let url = detector.detect(in: "go: https://claude.com/oauth/authorize?code=true&state=x")
        #expect(url == nil)
    }

    @Test("ignores a look-alike host carrying the /cai/ authorize path (host lock, security)")
    func detectIgnoresArbitraryHost() {
        var detector = OAuthURLDetector()
        let url = detector.detect(in: "go: https://evil.example.com/cai/oauth/authorize?code=true&state=x")
        #expect(url == nil)
    }

    @Test("ignores other claude.com URLs entirely (security)")
    func detectIgnoresOtherClaudeURL() {
        var detector = OAuthURLDetector()
        #expect(detector.detect(in: "see https://claude.com/settings/usage?tab=credits") == nil)
    }

    @Test("ignores platform.claude.com URLs off the authorize path (security)")
    func detectIgnoresOtherPlatformURL() {
        var detector = OAuthURLDetector()
        #expect(detector.detect(in: "see https://platform.claude.com/settings/keys") == nil)
    }

    // MARK: - Boundary / dedup / absence (behavior preserved from the single form)

    @Test("does not absorb the text after the URL (blank-line boundary)")
    func detectStopsAtBlankLine() {
        var detector = OAuthURLDetector()
        let buffer = "\(consoleURL)\n\nPaste code here if prompted >"
        #expect(detector.detect(in: buffer)?.absoluteString == consoleURL)
    }

    @Test("yields the same URL at most once across re-scans")
    func detectDedupesSameURL() {
        var detector = OAuthURLDetector()
        let buffer = "x\n\(consoleURL)\n\ny"
        #expect(detector.detect(in: buffer) != nil)   // first scan yields it
        #expect(detector.detect(in: buffer) == nil)    // re-scan of the growing buffer: no re-open
    }

    @Test("returns nil when no authorize URL is present")
    func detectReturnsNilWhenAbsent() {
        var detector = OAuthURLDetector()
        #expect(detector.detect(in: "just some terminal output, nothing to open") == nil)
    }

    @Test("a fresh URL is not shadowed by an already-seen earlier one (#30 verify)")
    func detectSecondURLAfterSeenFirstIsNotShadowed() {
        var detector = OAuthURLDetector()
        // A failed Claude.ai login re-prompts with a Console URL: the reset-immune
        // window (#30) keeps the seen first token resident; the detector must skip
        // it and return the fresh (different-form) URL — not nil.
        #expect(detector.detect(in: "Login: \(claudeAiURL)\n\n")?.absoluteString == claudeAiURL)
        let both = "Login: \(claudeAiURL)\n\nRetry: \(consoleURL)\n\n"
        #expect(detector.detect(in: both)?.absoluteString == consoleURL)
        #expect(detector.detect(in: both) == nil)   // both now seen → no re-open
    }
}
