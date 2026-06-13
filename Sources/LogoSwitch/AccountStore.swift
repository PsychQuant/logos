import Foundation

/// The persisted account index (#34) — a value aggregate of what `AccountManager`
/// keeps across launches. `forcedReauthIds` is deliberately NOT here: a live 401
/// is session-specific and must never carry across launches (#31).
public struct AccountIndex: Sendable, Equatable {
    public var accounts: [Account]
    public var activeAccountId: String?
    public var authenticatedAccountIds: [String]
    public var migrated: Bool

    public init(
        accounts: [Account] = [],
        activeAccountId: String? = nil,
        authenticatedAccountIds: [String] = [],
        migrated: Bool = false
    ) {
        self.accounts = accounts
        self.activeAccountId = activeAccountId
        self.authenticatedAccountIds = authenticatedAccountIds
        self.migrated = migrated
    }

    public static let empty = AccountIndex()
}

/// Account persistence (#34). **`@MainActor`, not `Sendable`** — every caller is
/// the `@MainActor` `AccountManager`, and the production impl stores a
/// non-`Sendable` `UserDefaults`; making the protocol `Sendable` would not
/// compile (the Swift6 verify must-fix).
@MainActor public protocol AccountStore {
    func load() -> AccountIndex
    func save(_ index: AccountIndex)
}

/// Production store. Reads/writes the SAME four `logos.accounts*` UserDefaults
/// keys the pre-#34 `AccountManager` used — NOT a single serialized blob — so an
/// existing user's accounts / active selection / authenticated flags / migration
/// state survive the upgrade. A naive single-`AccountIndex` decode would find
/// nothing under the legacy keys and silently wipe every account (the data-loss
/// must-fix); each field is read independently with a safe default.
@MainActor public final class UserDefaultsAccountStore: AccountStore {

    private enum Key {
        static let accounts = "logos.accounts"
        static let activeId = "logos.accounts.activeId"
        static let authenticatedIds = "logos.accounts.authenticatedIds"
        static let migrated = "logos.accounts.migratedIsolatedCredentials"
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
        if let ids = defaults.array(forKey: Key.authenticatedIds) as? [String] {
            index.authenticatedAccountIds = ids
        }
        index.migrated = defaults.bool(forKey: Key.migrated)
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
        defaults.set(index.authenticatedAccountIds, forKey: Key.authenticatedIds)
        defaults.set(index.migrated, forKey: Key.migrated)
    }
}

/// In-memory store for tests.
@MainActor public final class InMemoryAccountStore: AccountStore {
    private var index: AccountIndex
    public init(_ initial: AccountIndex = .empty) { self.index = initial }
    public func load() -> AccountIndex { index }
    public func save(_ index: AccountIndex) { self.index = index }
}
