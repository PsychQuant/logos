import Testing
import Foundation
@testable import Logos

@Suite("AutoHandleEngine rule toggle persistence", .serialized)
@MainActor
struct AutoHandleEngineRuleToggleTests {

    @Test("disabled rule persists across new engine init")
    func disabledPersists() throws {
        let dir = NSTemporaryDirectory() + "logos-ae-\(UUID().uuidString)"
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let e1 = AutoHandleEngine(persistence: p)
        e1.disableRule(id: "rate-limit")
        #expect(e1.disabledRuleIDs.contains("rate-limit"))

        let e2 = AutoHandleEngine(persistence: p)
        #expect(e2.disabledRuleIDs.contains("rate-limit"))
    }

    @Test("enable removes from persisted disabled set")
    func enableRemoves() throws {
        let dir = NSTemporaryDirectory() + "logos-ae-\(UUID().uuidString)"
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let e1 = AutoHandleEngine(persistence: p)
        e1.disableRule(id: "rate-limit")
        e1.enableRule(id: "rate-limit")

        let e2 = AutoHandleEngine(persistence: p)
        #expect(!e2.disabledRuleIDs.contains("rate-limit"))
    }
}
