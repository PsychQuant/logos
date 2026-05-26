import Testing
import Foundation
@testable import Logos

@Suite("AutoHandleEngine", .serialized)
@MainActor
struct AutoHandleEngineTests {

    @Test("fires matching rule and returns response bytes")
    func firesMatchingRule() {
        let engine = AutoHandleEngine(rules: [
            AutoHandleRule(id: "x", name: "x", pattern: "trigger", response: "ok\n", cooldown: 0.001)
        ])
        let response = engine.processChunk("Hello trigger world")
        #expect(response == Array("ok\n".utf8))
    }

    @Test("no fire on non-matching input")
    func noFireOnMiss() {
        let engine = AutoHandleEngine(rules: [
            AutoHandleRule(id: "x", name: "x", pattern: "trigger", response: "ok\n", cooldown: 0.001)
        ])
        let response = engine.processChunk("Hello world")
        #expect(response == nil)
    }

    @Test("respects cooldown")
    func respectsCooldown() async throws {
        let engine = AutoHandleEngine(rules: [
            AutoHandleRule(id: "x", name: "x", pattern: "trigger", response: "ok\n", cooldown: 1.0)
        ])
        _ = engine.processChunk("trigger 1")
        // Immediately second match — should NOT fire (cooldown active)
        let response = engine.processChunk("trigger 2")
        #expect(response == nil)
    }

    @Test("disables rule after runaway")
    func runawayDisable() {
        let engine = AutoHandleEngine(rules: [
            AutoHandleRule(id: "x", name: "x", pattern: "trigger", response: "ok\n", cooldown: 0.001)
        ])
        // Fire 3+ times within 30s — should auto-disable
        for _ in 0..<5 {
            _ = engine.processChunk("trigger")
            Thread.sleep(forTimeInterval: 0.002)  // exceed cooldown but stay within 30s window
        }
        #expect(engine.disabledRuleIDs.contains("x"))
    }

    @Test("status reflects rule states")
    func statusReflection() {
        let engine = AutoHandleEngine(rules: AutoHandleRule.defaultRuleset)
        #expect(engine.currentStatus == .armed)
        // After disabling one rule manually:
        engine.disableRule(id: "rate-limit")
        #expect(engine.currentStatus == .partial)
        // Disable all:
        for rule in AutoHandleRule.defaultRuleset {
            engine.disableRule(id: rule.id)
        }
        #expect(engine.currentStatus == .disabled)
    }
}
