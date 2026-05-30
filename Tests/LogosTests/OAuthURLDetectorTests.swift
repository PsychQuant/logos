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

    @Test("reassembles a URL the terminal hard-wrapped across lines")
    func detectReassemblesWrappedURL() {
        var detector = OAuthURLDetector()
        // Simulate Ink/terminal hard-wrap: single newlines inserted INSIDE the URL,
        // then a blank line before the next prompt.
        let wrapped =
            "https://claude.com/cai/oauth/authorize?code=true&\nclient_id=abc-123&\nstate=xyz-789\n\nPaste code >"
        let url = detector.detect(in: wrapped)
        #expect(url?.absoluteString == authorizeURL)
    }

    @Test("returns nil when no authorize URL is present")
    func detectReturnsNilWhenAbsent() {
        var detector = OAuthURLDetector()
        #expect(detector.detect(in: "just some terminal output, nothing to open") == nil)
    }
}
