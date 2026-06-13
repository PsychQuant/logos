import Foundation

/// What `AccountManager` persists across launches — the account list + the active
/// selection. Nothing auth-related: no authenticated flags, no migration marker.
/// Auth state is claude's own job (#34), and the live-401 nudge (#31) is
/// session-volatile, so neither is persisted.
public struct AccountIndex: Sendable, Equatable {
    public var accounts: [Account]
    public var activeAccountId: String?

    public init(accounts: [Account] = [], activeAccountId: String? = nil) {
        self.accounts = accounts
        self.activeAccountId = activeAccountId
    }

    public static let empty = AccountIndex()
}

/// Account persistence (#34). **`@MainActor`, not `Sendable`** — every caller is
/// the `@MainActor` `AccountManager`, and the production impl stores a
/// non-`Sendable` `UserDefaults`.
@MainActor public protocol AccountStore {
    func load() -> AccountIndex
    func save(_ index: AccountIndex)
}

/// Production store, on the same `logos.accounts*` UserDefaults keys used since
/// before #34 (so an existing user's accounts + active selection survive the
/// upgrade). Pre-#34 also wrote `logos.accounts.authenticatedIds` /
/// `.migratedIsolatedCredentials`; those are no longer read or written (auth state
/// is claude's job now) — any stale values are simply ignored.
@MainActor public final class UserDefaultsAccountStore: AccountStore {

    private enum Key {
        static let accounts = "logos.accounts"
        static let activeId = "logos.accounts.activeId"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AccountIndex {
        var index = AccountIndex.empty
        if let data = defaults.data(forKey: Key.accounts),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            index.accounts = decoded
        }
        index.activeAccountId = defaults.string(forKey: Key.activeId)
        return index
    }

    public func save(_ index: AccountIndex) {
        if let data = try? JSONEncoder().encode(index.accounts) {
            defaults.set(data, forKey: Key.accounts)
        }
        if let id = index.activeAccountId {
            defaults.set(id, forKey: Key.activeId)
        } else {
            defaults.removeObject(forKey: Key.activeId)
        }
    }
}

/// In-memory store for tests.
@MainActor public final class InMemoryAccountStore: AccountStore {
    private var index: AccountIndex
    public init(_ initial: AccountIndex = .empty) { self.index = initial }
    public func load() -> AccountIndex { index }
    public func save(_ index: AccountIndex) { self.index = index }
}
