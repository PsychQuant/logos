import Testing
@testable import Logos

@Suite("AutoHandleRule", .serialized)
@MainActor
struct AutoHandleRuleTests {

    @Test("rule matches expected pattern in input")
    func patternMatches() {
        let rule = AutoHandleRule(
            id: "rate-limit",
            name: "Rate limit keep-going",
            pattern: #"Press "keep going" to retry"#,
            response: "keep going\n",
            cooldown: 5
        )
        let input = "API Error: Rate limited. Press \"keep going\" to retry..."
        #expect(rule.matches(input))
    }

    @Test("rule does not match unrelated input")
    func patternDoesNotMatch() {
        let rule = AutoHandleRule(
            id: "rate-limit",
            name: "Rate limit",
            pattern: #"Press "keep going" to retry"#,
            response: "keep going\n",
            cooldown: 5
        )
        #expect(!rule.matches("Hello world"))
    }

    @Test("response bytes computed correctly")
    func responseBytes() {
        let rule = AutoHandleRule(
            id: "x",
            name: "x",
            pattern: "x",
            response: "y\n",
            cooldown: 1
        )
        #expect(rule.responseBytes == Array("y\n".utf8))
    }

    @Test("invalid regex pattern surfaces in matches() returning false")
    func invalidPatternHandled() {
        let rule = AutoHandleRule(
            id: "bad",
            name: "Bad regex",
            pattern: "[unclosed",
            response: "x",
            cooldown: 1
        )
        // Should not crash; should return false
        #expect(!rule.matches("anything"))
    }
}
