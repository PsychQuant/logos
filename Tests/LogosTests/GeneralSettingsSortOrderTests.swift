import Testing
import Foundation
import LogosUsage
@testable import Logos

/// #112: the sort choice has to survive a window close, and a preference file written by a
/// build that predates #112 must still decode — otherwise adding this field would silently
/// reset the user's theme back to the default.
@Suite("GeneralSettings.usageSortOrder", .serialized)
@MainActor
struct GeneralSettingsSortOrderTests {

    private func tempPersistence() throws -> (SettingsPersistence, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logos-112-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SettingsPersistence(directory: dir.path), dir)
    }

    @Test("defaults to registry order, so the window looks unchanged until opted in")
    func defaultsToRegistry() throws {
        let (persistence, dir) = try tempPersistence()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GeneralSettings(persistence: persistence).usageSortOrder == .registry)
    }

    @Test("the chosen order round-trips through the preference file")
    func roundTrips() throws {
        let (persistence, dir) = try tempPersistence()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = GeneralSettings(persistence: persistence)
        first.usageSortOrder = .weeklyUrgency

        #expect(GeneralSettings(persistence: persistence).usageSortOrder == .weeklyUrgency)
    }

    /// A general.json written before #112 has no `usageSortOrder` key. Decoding must fall
    /// back rather than throw — a throw here would discard the whole file, silently
    /// resetting theme and workspace-restore too.
    @Test("a pre-#112 preference file still decodes, keeping its other settings")
    func legacyFileStillDecodes() throws {
        let (persistence, dir) = try tempPersistence()
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = #"{"restoreLastWorkspaceOnLaunch":false,"theme":"light"}"#
        try legacy.write(
            to: dir.appendingPathComponent("general.json"), atomically: true, encoding: .utf8)

        let settings = GeneralSettings(persistence: persistence)
        #expect(settings.usageSortOrder == .registry, "missing key should fall back")
        #expect(settings.theme == .light, "the rest of the legacy file must survive")
        #expect(settings.restoreLastWorkspaceOnLaunch == false)
    }
}
