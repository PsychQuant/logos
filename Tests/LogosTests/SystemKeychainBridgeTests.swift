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

    @Test("write then read returns same data")
    func writeRead() throws {
        let bridge = InMemorySystemKeychainBridge()
        let blob = Data("{\"claudeAiOauth\":{}}".utf8)
        try bridge.write(blob)
        #expect(try bridge.read() == blob)
        #expect(bridge.exists() == true)
    }

    @Test("write overwrites previous")
    func writeOverwrites() throws {
        let bridge = InMemorySystemKeychainBridge()
        try bridge.write(Data("v1".utf8))
        try bridge.write(Data("v2".utf8))
        #expect(try bridge.read() == Data("v2".utf8))
    }

    @Test("delete clears entry")
    func deleteClear() throws {
        let bridge = InMemorySystemKeychainBridge()
        try bridge.write(Data("x".utf8))
        try bridge.delete()
        #expect(try bridge.read() == nil)
    }

    @Test("delete missing throws notFound")
    func deleteMissing() {
        let bridge = InMemorySystemKeychainBridge()
        #expect(throws: AccountCredentialStoreError.notFound) {
            try bridge.delete()
        }
    }

    @Test("initial value seeded via init")
    func initialSeed() throws {
        let bridge = InMemorySystemKeychainBridge(initial: Data("seed".utf8))
        #expect(try bridge.read() == Data("seed".utf8))
        #expect(bridge.exists() == true)
    }
}
