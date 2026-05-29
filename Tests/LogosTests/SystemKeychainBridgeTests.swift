import Testing
import Foundation
@testable import Logos

@Suite("SystemKeychainBridge", .serialized)
@MainActor
struct SystemKeychainBridgeTests {

    @Test("in-memory starts empty")
    func emptyInitially() throws {
        let bridge = InMemorySystemKeychainBridge()
        #expect(try bridge.read() == nil)
        #expect(bridge.exists() == false)
    }

    // NOTE: write/delete tests were removed with the write/delete methods
    // (PsychQuant/logos#12) — the bridge is now read-only. Seeding for read
    // tests is done via `init(initial:)`.

    @Test("initial value seeded via init")
    func initialSeed() throws {
        let bridge = InMemorySystemKeychainBridge(initial: Data("seed".utf8))
        #expect(try bridge.read() == Data("seed".utf8))
        #expect(bridge.exists() == true)
    }
}
