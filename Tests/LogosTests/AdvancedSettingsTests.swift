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

    // MARK: - Gateway (spec 2026-07-31)

    @Test("gateway defaults: enabled, auto-detect command")
    func gatewayDefaults() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        #expect(s.gatewayEnabled == true)
        #expect(s.gatewayCommand == nil)
    }

    @Test("gateway command persists as argv")
    func gatewayCommandPersists() {
        let dir = tempDir()
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let s1 = AdvancedSettings(persistence: p)
        // A path containing a space proves argv storage: a shell-string field would
        // need quoting here and would word-split on read.
        s1.gatewayCommand = ["/usr/bin/env", "python3", "/tmp/my proxy.py"]
        s1.gatewayEnabled = false

        let s2 = AdvancedSettings(persistence: p)
        #expect(s2.gatewayCommand == ["/usr/bin/env", "python3", "/tmp/my proxy.py"])
        #expect(s2.gatewayEnabled == false)
    }

    @Test("an empty or all-blank gateway command is treated as nil")
    func emptyGatewayCommandAsNil() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        s.gatewayCommand = []
        #expect(s.gatewayCommand == nil)
        s.gatewayCommand = ["", ""]
        #expect(s.gatewayCommand == nil)
    }

    /// A pre-gateway advanced.json must still decode. A non-optional field in the
    /// DTO would fail the decode and reset EVERY advanced setting.
    @Test("legacy advanced.json without gateway fields still decodes")
    func legacyDecodeKeepsOtherSettings() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let legacy = #"{"claudePathOverride":"/opt/homebrew/bin/claude","logLevel":"debug"}"#
        try Data(legacy.utf8).write(to: URL(fileURLWithPath: dir + "/advanced.json"))

        let s = AdvancedSettings(persistence: SettingsPersistence(directory: dir))
        #expect(s.claudePathOverride == "/opt/homebrew/bin/claude")
        #expect(s.logLevel == .debug)
        #expect(s.gatewayEnabled == true)
        #expect(s.gatewayCommand == nil)
    }

    private func tempDir() -> String {
        NSTemporaryDirectory() + "logos-as-\(UUID().uuidString)"
    }
}
