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

    @Test("dangerous mode defaults off; claudeExtraArgs empty")
    func dangerousModeDefaultsOff() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        #expect(s.dangerouslySkipPermissions == false)
        #expect(s.claudeExtraArgs == [])
    }

    @Test("dangerous mode maps to the launch flag")
    func dangerousModeMapsToFlag() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        s.dangerouslySkipPermissions = true
        #expect(s.claudeExtraArgs == ["--dangerously-skip-permissions"])
    }

    @Test("dangerous mode persists across reload")
    func dangerousModePersists() {
        let dir = tempDir()
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let s1 = AdvancedSettings(persistence: p)
        s1.dangerouslySkipPermissions = true

        let s2 = AdvancedSettings(persistence: p)
        #expect(s2.dangerouslySkipPermissions == true)
        #expect(s2.claudeExtraArgs == ["--dangerously-skip-permissions"])
    }

    @Test("legacy advanced.json without the field loads without resetting other settings")
    func legacyJSONBackCompat() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // A pre-existing advanced.json from before the dangerous-mode field was added.
        let legacy = #"{"claudePathOverride":"/opt/homebrew/bin/claude","logLevel":"debug"}"#
        try legacy.data(using: .utf8)!.write(to: URL(fileURLWithPath: "\(dir)/advanced.json"))

        let s = AdvancedSettings(persistence: SettingsPersistence(directory: dir))
        // Existing fields survive — the missing new field must NOT fail the decode
        // (which would reset ALL advanced settings, losing claudePathOverride).
        #expect(s.claudePathOverride == "/opt/homebrew/bin/claude")
        #expect(s.logLevel == .debug)
        // New field defaults to false.
        #expect(s.dangerouslySkipPermissions == false)
    }

    private func tempDir() -> String {
        NSTemporaryDirectory() + "logos-as-\(UUID().uuidString)"
    }
}
