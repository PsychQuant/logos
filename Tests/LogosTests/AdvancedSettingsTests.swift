import Testing
import Foundation
@testable import Logos

@Suite("AdvancedSettings", .serialized)
@MainActor
struct AdvancedSettingsTests {

    @Test("defaults")
    func defaults() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        #expect(s.claudePathOverride == nil)
        #expect(s.logLevel == .info)
    }

    @Test("override persists")
    func overridePersists() throws {
        let dir = tempDir()
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let s1 = AdvancedSettings(persistence: p)
        s1.claudePathOverride = "/opt/homebrew/bin/claude"
        s1.logLevel = .debug

        let s2 = AdvancedSettings(persistence: p)
        #expect(s2.claudePathOverride == "/opt/homebrew/bin/claude")
        #expect(s2.logLevel == .debug)
    }

    @Test("empty string treated as nil")
    func emptyAsNil() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        s.claudePathOverride = ""
        #expect(s.claudePathOverride == nil)
    }

    private func tempDir() -> String {
        NSTemporaryDirectory() + "logos-as-\(UUID().uuidString)"
    }
}
