import Foundation

/// Persists the launcher's active-account selection — and nothing else.
///
/// The account list itself moved to the shared `AccountRegistry` index file
/// (merge-multistats-into-logos): "Active selection stays out of the shared
/// registry" — it is per-app launcher UI state, so it stays in Logos-local
/// UserDefaults while the list is shared with the standalone viewer.
///
/// The pre-registry `logos.accounts` blob is deliberately NOT written (or
/// deleted) here anymore: it is the read-fallback for the registry's one-time
/// migration and must stay untouched so downgrades remain harmless.
@MainActor public protocol ActiveAccountStore {
    func loadActiveAccountId() -> String?
    func saveActiveAccountId(_ id: String?)
}

/// Production store. Keeps the same `logos.accounts.activeId` key used since
/// before the registry split, so an existing user's selection survives the
/// upgrade.
@MainActor public final class UserDefaultsActiveAccountStore: ActiveAccountStore {

    private enum Key {
        static let activeId = "logos.accounts.activeId"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadActiveAccountId() -> String? {
        defaults.string(forKey: Key.activeId)
    }

    public func saveActiveAccountId(_ id: String?) {
        if let id {
            defaults.set(id, forKey: Key.activeId)
        } else {
            defaults.removeObject(forKey: Key.activeId)
        }
    }
}

/// In-memory store for tests.
@MainActor public final class InMemoryActiveAccountStore: ActiveAccountStore {
    private var activeId: String?
    public init(_ initial: String? = nil) { self.activeId = initial }
    public func loadActiveAccountId() -> String? { activeId }
    public func saveActiveAccountId(_ id: String?) { activeId = id }
}
