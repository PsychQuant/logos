import Testing
import Foundation
@testable import Logos

@Suite("WorkspacePersistence", .serialized)
final class WorkspacePersistenceTests {

    // #16: a class suite so `deinit` can release the isolated UserDefaults
    // suites built during each test (no orphan plists in ~/Library/Preferences).
    private let tracker = IsolatedDefaultsTracker()
    deinit { tracker.teardown() }

    @Test("save and load round-trip")
    func saveAndLoadRoundtrip() throws {
        let defaults = isolatedDefaults()
        let p = WorkspacePersistence(defaults: defaults)
        let path = "/Users/test/projects/foo"

        p.saveLastPath(path)
        #expect(p.loadLastPath() == path)
    }

    @Test("loadLastPath returns nil when unset")
    func loadLastPathReturnsNilWhenUnset() {
        let defaults = isolatedDefaults()
        let p = WorkspacePersistence(defaults: defaults)
        #expect(p.loadLastPath() == nil)
    }

    @Test("clear removes saved value")
    func clearRemovesValue() {
        let defaults = isolatedDefaults()
        let p = WorkspacePersistence(defaults: defaults)
        p.saveLastPath("/some/path")
        #expect(p.loadLastPath() != nil)

        p.clear()
        #expect(p.loadLastPath() == nil)
    }

    private func isolatedDefaults() -> UserDefaults {
        tracker.make(prefix: "logos.test")
    }
}
