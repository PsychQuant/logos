import Testing
import Foundation
@testable import Logos

// Shared test support for isolated `UserDefaults` suites (PsychQuant/logos#16).
//
// Several test suites isolate persistence state by injecting
// `UserDefaults(suiteName: "<prefix>.<UUID>")` so a save side effect never
// pollutes `UserDefaults.standard`. Each isolated suite registers a persistent
// domain with the OS, so without teardown every isolated test instantiation
// leaves an orphan plist in `~/Library/Preferences`.
//
// `IsolatedDefaultsTracker` records every suite name it hands out and removes
// the matching persistent domain on `teardown()`. Suites that use it must be a
// `final class` (not a `struct`) and call `tracker.teardown()` from `deinit`,
// because swift-testing constructs a fresh suite instance per `@Test` and only
// a class has a `deinit` hook to release the OS-registered suites after the
// test (and any model it owns) is torn down.
//
// Verification (regression guard, run after a full `swift test`):
//   ls ~/Library/Preferences | grep -E '^(logos\.test|LogosE2|ACI)' | wc -l
// should print 0, or at least show no net growth across two consecutive runs.
//
// The state is `NSLock`-guarded and the type is `@unchecked Sendable` because
// `make(prefix:)` is called from a suite's `@MainActor` body while `teardown()`
// is reached from the nonisolated `deinit`; both touch the tracked-name array.
final class IsolatedDefaultsTracker: @unchecked Sendable {

    private let lock = NSLock()
    private var suiteNames: [String] = []

    /// Builds a fresh isolated `UserDefaults` suite under `prefix`, records its
    /// suite name for later teardown, and returns it.
    func make(prefix: String) -> UserDefaults {
        let suiteName = "\(prefix).\(UUID().uuidString)"
        lock.lock()
        suiteNames.append(suiteName)
        lock.unlock()
        return UserDefaults(suiteName: suiteName)!
    }

    /// Removes the persistent domain for every suite handed out so far and
    /// clears the tracked list. Safe to call more than once.
    ///
    /// `removePersistentDomain(forName:)` empties the suite's values but does
    /// NOT delete the backing plist — `cfprefsd` writes back an empty shell
    /// (`{}`) in `~/Library/Preferences`, which still accumulates as an orphan
    /// file. To genuinely stop orphans from piling up (PsychQuant/logos#16) we
    /// also delete the on-disk plist after removing the domain.
    func teardown() {
        lock.lock()
        let names = suiteNames
        suiteNames.removeAll()
        lock.unlock()
        let prefsDir = (("~/Library/Preferences" as NSString).expandingTildeInPath)
        for name in names {
            UserDefaults.standard.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(atPath: "\(prefsDir)/\(name).plist")
        }
    }
}

@Suite("IsolatedDefaultsTracker", .serialized)
struct IsolatedDefaultsTrackerTests {

    @Test("teardown removes the persistent domain")
    func trackerTeardownRemovesPersistentDomain() {
        let tracker = IsolatedDefaultsTracker()
        let defaults = tracker.make(prefix: "logos.test.tracker")

        defaults.set("present", forKey: "sentinel")
        #expect(defaults.string(forKey: "sentinel") == "present")

        tracker.teardown()

        // removePersistentDomain clears the suite's persisted + in-memory store,
        // so the value is gone for the same suite name.
        #expect(defaults.string(forKey: "sentinel") == nil)
    }

    @Test("teardown drains all tracked suites")
    func trackerTracksMultipleSuites() {
        let tracker = IsolatedDefaultsTracker()
        let a = tracker.make(prefix: "logos.test.tracker")
        let b = tracker.make(prefix: "logos.test.tracker")
        let c = tracker.make(prefix: "logos.test.tracker")

        a.set("va", forKey: "k")
        b.set("vb", forKey: "k")
        c.set("vc", forKey: "k")
        #expect(a.string(forKey: "k") == "va")
        #expect(b.string(forKey: "k") == "vb")
        #expect(c.string(forKey: "k") == "vc")

        tracker.teardown()

        #expect(a.string(forKey: "k") == nil)
        #expect(b.string(forKey: "k") == nil)
        #expect(c.string(forKey: "k") == nil)
    }
}
