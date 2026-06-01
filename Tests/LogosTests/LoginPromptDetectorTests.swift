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

    @Test("bare /login phrase without a 401 marker does NOT fire (false-positive guard, #29 verify)")
    func bareLoginPhraseWithoutErrorDoesNotFire() {
        var d = LoginPromptDetector()
        // User typing the phrase, or claude quoting it in help text — no 401 → no banner.
        #expect(d.detect(in: "Tip: you can type /login anytime. Please run /login to switch accounts.") == false)
    }

    @Test("no storm — fires once per appearance, not on re-scan of the growing buffer")
    func noStormWhileSignalPresent() {
        var d = LoginPromptDetector()
        let buf = "Please run /login · API Error: 401"
        #expect(d.detect(in: buf) == true)
        #expect(d.detect(in: buf) == false)
        #expect(d.detect(in: buf + " ...more output appended later") == false)
    }

    @Test("re-fires on a genuinely new 401 after the previous one clears (rising edge, #30 Item 2a)")
    func reFiresOnNewOccurrence() {
        var d = LoginPromptDetector()
        let sig = "Please run /login · API Error: 401"
        #expect(d.detect(in: sig) == true)                              // absent→present: fire
        #expect(d.detect(in: sig) == false)                             // still present: no fire
        #expect(d.detect(in: "Welcome back! How can I help?") == false) // present→absent: re-arm
        #expect(d.detect(in: sig) == true)                              // absent→present again: fire
    }

    @Test("dismiss does not re-fire while the same 401 still sits in the buffer (#30 Item 2a)")
    func noReFireWhileSignalStillPresent() {
        var d = LoginPromptDetector()
        let sig = "API Error: 401 Invalid authentication credentials"
        #expect(d.detect(in: sig) == true)   // fire — banner shows
        // User dismisses; the next chunk still contains the 401 (not scrolled out
        // yet). No NEW rising edge → the banner does not pop straight back.
        #expect(d.detect(in: sig + "\nstill here") == false)
    }

    @Test("fires when the 401 signal is split across two buffer appends (#30 Item 1)")
    func firesOnSignalSplitAcrossChunks() {
        var buf = RollingTerminalBuffer()
        var d = LoginPromptDetector()
        buf.append("Please run /login")
        #expect(d.detect(in: buf.contents) == false)   // only /login, no 401 yet
        buf.append(" · API Error: 401")
        #expect(d.detect(in: buf.contents) == true)    // both halves present → fire
    }
}
