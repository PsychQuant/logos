import Testing
import Foundation
@testable import Logos

@Suite("AccountCredentialStore", .serialized)
@MainActor
struct AccountCredentialStoreTests {

    @Test("save then load returns same blob")
    func saveLoadRoundtrip() throws {
        let store = InMemoryCredentialStore()
        let blob = Data("{\"token\":\"abc\"}".utf8)
        try store.save(accountId: "test", credentials: blob)
        let loaded = try store.load(accountId: "test")
        #expect(loaded == blob)
    }

    @Test("load missing account throws")
    func loadMissing() {
        let store = InMemoryCredentialStore()
        #expect(throws: AccountCredentialStoreError.notFound) {
            _ = try store.load(accountId: "nonexistent")
        }
    }

    @Test("delete removes entry")
    func deleteRemoves() throws {
        let store = InMemoryCredentialStore()
        try store.save(accountId: "x", credentials: Data("blob".utf8))
        try store.delete(accountId: "x")
        #expect(throws: AccountCredentialStoreError.notFound) {
            _ = try store.load(accountId: "x")
        }
    }

    @Test("list returns saved account ids")
    func list() throws {
        let store = InMemoryCredentialStore()
        try store.save(accountId: "a", credentials: Data("x".utf8))
        try store.save(accountId: "b", credentials: Data("y".utf8))
        let ids = try store.listAccountIds().sorted()
        #expect(ids == ["a", "b"])
    }

    @Test("overwrite same accountId updates blob")
    func overwrite() throws {
        let store = InMemoryCredentialStore()
        try store.save(accountId: "x", credentials: Data("v1".utf8))
        try store.save(accountId: "x", credentials: Data("v2".utf8))
        let loaded = try store.load(accountId: "x")
        #expect(loaded == Data("v2".utf8))
    }
}
