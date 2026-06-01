import Testing
import Foundation
@testable import Logos

/// Tests for the claude OAuth authorize-URL detector (PsychQuant/logos#17).
/// The detector scans ANSI-stripped terminal output for the claude login URL so
/// Logos can open it natively (claude's own browser-open fails inside Logos's
/// spawned-PTY launchd context). SECURITY: it must match ONLY the claude
/// authorize URL — never a general URL opener.
@Suite("OAuthURLDetector", .serialized)
@MainActor
struct OAuthURLDetectorTests {

    private let authorizeURL =
        "https://claude.com/cai/oauth/authorize?code=true&client_id=abc-123&state=xyz-789"

    @Test("finds the claude authorize URL in surrounding output")
    func detectFindsAuthorizeURL() {
        var detector = OAuthURLDetector()
        let buffer = """
        Browser didn't open? Use the url below to sign in (c to copy)

        \(authorizeURL)

        Paste code here if prompted >
        """
        let url = detector.detect(in: buffer)
        #expect(url?.absoluteString == authorizeURL)
    }

    @Test("ignores a same-shaped URL on a non-claude host (security)")
    func detectIgnoresArbitraryHost() {
        var detector = OAuthURLDetector()
        let url = detector.detect(in: "go here: https://evil.example/cai/oauth/authorize?code=true&state=x")
        #expect(url == nil)
    }

    @Test("ignores other claude.com URLs (path lock, security)")
    func detectIgnoresOtherClaudeURL() {
        var detector = OAuthURLDetector()
        let url = detector.detect(in: "see https://claude.com/settings/usage?tab=credits")
        #expect(url == nil)
    }

    @Test("does not absorb the text after the URL (blank-line boundary)")
    func detectStopsAtBlankLine() {
        var detector = OAuthURLDetector()
        let buffer = "\(authorizeURL)\n\nPaste code here if prompted >"
        #expect(detector.detect(in: buffer)?.absoluteString == authorizeURL)
    }

    @Test("yields the same URL at most once across re-scans")
    func detectDedupesSameURL() {
        var detector = OAuthURLDetector()
        let buffer = "x\n\(authorizeURL)\n\ny"
        #expect(detector.detect(in: buffer) != nil)   // first scan yields it
        #expect(detector.detect(in: buffer) == nil)    // re-scan of accumulating buffer: no re-open
    }

    @Test("reassembles a URL the terminal hard-wrapped with CRLF across lines")
    func detectReassemblesWrappedURL() {
        var detector = OAuthURLDetector()
        // The real terminal wrap is `\r\r\n` (CR CR LF), NOT a single `\n`.
        let wrapped =
            "https://claude.com/cai/oauth/authorize?code=true&\r\r\nclient_id=abc-123&\r\r\nstate=xyz-789\r\r\n\r\r\nPaste code >"
        let url = detector.detect(in: wrapped)
        #expect(url?.absoluteString == authorizeURL)
    }

    /// Gold-standard fixture: the actual ANSI-stripped buffer captured from a real
    /// `claude login` (v2.1.158) — `\r\r\n` wrapping the URL every ~78 cols, three
    /// `\r\r\n` blank-line breaks, then the space-stripped "Paste code…" prompt.
    @Test("reassembles the real captured claude-login URL block")
    func detectRealCapturedURLBlock() {
        var detector = OAuthURLDetector()
        let captured =
            "rl below to sign in (c to copy)\r\r\n\r\r\n" +
            "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88\r\r\n" +
            "ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.co\r\r\n" +
            "m%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainf\r\r\n" +
            "erence+user%3Asessions%3Aclaude_code+user%3Amcp_servers+user%3Afile_upload&code_\r\r\n" +
            "challenge=SQtfq9eMXwJ0ezSJhh2_SlWgHzOV3JzNEUv5An0Zr78&code_challenge_method=S256\r\r\n" +
            "&state=JXzYippVmAHWmvV__aN12VaUPRwT3JC050DRE9xnnGQ\r\r\n\r\r\n\r\r\nPastecodehereifprompted>"
        let expected =
            "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e" +
            "&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback" +
            "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code" +
            "+user%3Amcp_servers+user%3Afile_upload" +
            "&code_challenge=SQtfq9eMXwJ0ezSJhh2_SlWgHzOV3JzNEUv5An0Zr78&code_challenge_method=S256" +
            "&state=JXzYippVmAHWmvV__aN12VaUPRwT3JC050DRE9xnnGQ"
        #expect(detector.detect(in: captured)?.absoluteString == expected)
    }

    @Test("returns nil when no authorize URL is present")
    func detectReturnsNilWhenAbsent() {
        var detector = OAuthURLDetector()
        #expect(detector.detect(in: "just some terminal output, nothing to open") == nil)
    }

    @Test("a new authorize URL is not shadowed by an already-seen earlier one (#30 verify, codex P2)")
    func detectSecondURLAfterSeenFirstIsNotShadowed() {
        var detector = OAuthURLDetector()
        let url1 = "https://claude.com/cai/oauth/authorize?code=true&client_id=AAA-111&state=one"
        let url2 = "https://claude.com/cai/oauth/authorize?code=true&client_id=BBB-222&state=two"
        // First login URL opens and is remembered.
        #expect(detector.detect(in: "Login: \(url1)\n\n")?.absoluteString == url1)
        // The reset-immune window (#30) keeps url1 resident; a failed login
        // re-prompts with url2. The detector must skip the stale url1 token and
        // return the fresh url2 — not nil (the pre-fix first-token-only shadowing).
        let both = "Login: \(url1)\n\nRetry: \(url2)\n\n"
        #expect(detector.detect(in: both)?.absoluteString == url2)
        // url2 is now also seen → no re-open on a subsequent identical scan.
        #expect(detector.detect(in: both) == nil)
    }
}
