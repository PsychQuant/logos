import Testing
import Foundation
@testable import Logos

@Suite("GeneralSettings", .serialized)
@MainActor
struct GeneralSettingsTests {

    @Test("defaults")
    func defaults() {
        let s = GeneralSettings(persistence: makePersistence())
        #expect(s.theme == .dark)   // #46: dark-by-default (terminal-host tool)
        #expect(s.restoreLastWorkspaceOnLaunch == true)
    }

    @Test("change persists immediately")
    func changesPersist() throws {
        let dir = NSTemporaryDirectory() + "logos-gs-\(UUID().uuidString)"
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let s1 = GeneralSettings(persistence: p)
        s1.theme = .dark
        s1.restoreLastWorkspaceOnLaunch = false

        let s2 = GeneralSettings(persistence: p)
        #expect(s2.theme == .dark)
        #expect(s2.restoreLastWorkspaceOnLaunch == false)
    }

    @Test("theme cases")
    func themeCases() {
        #expect(GeneralSettings.Theme.allCases.count == 3)
    }

    private func makePersistence() -> SettingsPersistence {
        let dir = NSTemporaryDirectory() + "logos-gs-\(UUID().uuidString)"
        return SettingsPersistence(directory: dir)
    }
}
