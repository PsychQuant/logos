import Foundation

/// Last-opened workspace path persistence. UserDefaults-backed for now
/// because Logos is not sandboxed (Info.plist has no
/// `com.apple.security.app-sandbox` entitlement) — security-scoped
/// bookmarks would add complexity without effect. When sandboxing is
/// adopted, swap the storage implementation inside this struct; callers
/// don't change.
// `@unchecked Sendable` — UserDefaults is a documented thread-safe Foundation
// class but not formally Sendable in the Swift overlay. The wrapping struct
// only reads/writes string-or-nil for one key, so the unchecked assertion is
// safe per UserDefaults's own concurrency contract.
public struct WorkspacePersistence: @unchecked Sendable {

    static let lastPathKey = "logos.lastWorkspacePath"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadLastPath() -> String? {
        defaults.string(forKey: Self.lastPathKey)
    }

    public func saveLastPath(_ path: String) {
        defaults.set(path, forKey: Self.lastPathKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.lastPathKey)
    }
}
