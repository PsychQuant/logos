import Testing
import Foundation
@testable import Logos

/// Tests for the hosted-claude unauthenticated-signal detector (PsychQuant/logos#29).
/// The detector scans ANSI-stripped terminal output for claude's `/login` / 401
/// strings so Logos can show a passive re-auth banner. It is READ-ONLY — it never
/// touches the token (the first-party-host constraint); these tests lock that the
/// match is tight (no nagging healthy sessions) and idempotent.
@Suite("LoginPromptDetector", .serialized)
@MainActor
struct LoginPromptDetectorTests {

    @Test("detects claude's 'Please run /login' recovery instruction")
    func detectsPleaseRunLogin() {
        var d = LoginPromptDetector()
        #expect(d.detect(in: "  ⎿  Please run /login · API Error: 401") == true)
    }

    @Test("detects the 401 invalid-credentials body")
    func detects401Body() {
        var d = LoginPromptDetector()
        #expect(d.detect(in: "API Error: 401 Invalid authentication credentials") == true)
    }

    @Test("matches the verbatim hosted-claude line from #29")
    func matchesVerbatimLine() {
        var d = LoginPromptDetector()
        let line = "Please run /login · API Error: 401 Invalid authentication credentials"
        #expect(d.detect(in: line) == true)
    }

    @Test("ignores unrelated / healthy output")
    func ignoresUnrelated() {
        var d = LoginPromptDetector()
        #expect(d.detect(in: "Welcome back kiki830621! How can I help you today?") == false)
        #expect(d.detect(in: "> 妳好") == false)
    }

    @Test("idempotent — fires once per instance, not on re-scan of the growing buffer")
    func idempotent() {
        var d = LoginPromptDetector()
        let buf = "Please run /login"
        #expect(d.detect(in: buf) == true)
        #expect(d.detect(in: buf) == false)
        #expect(d.detect(in: buf + " ...more output appended later") == false)
    }
}
