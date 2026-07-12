import Foundation

/// Last-opened workspace **locator** persistence. The stored string is a workspace
/// locator (#96): either a `.code-workspace` file path or a plain folder path. On
/// restore, `WorkspaceModel.resolveWorkspace` selects the `.code-workspace` reader by
/// extension and otherwise treats the locator as an ad-hoc folder — so a value written
/// before this capability existed (always a bare folder path) restores as a one-root
/// ad-hoc workspace with no migration step. The storage stays a single string; only the
/// *meaning* widened from "folder path" to "locator", so the API is unchanged.
///
/// UserDefaults-backed for now because Logos is not sandboxed (Info.plist has no
/// `com.apple.security.app-sandbox` entitlement) — security-scoped
/// bookmarks would add complexity without effect. When sandboxing is
/// adopted, swap the storage implementation inside this struct; callers
/// don't change.
// `@unchecked Sendable` — UserDefaults is a documented thread-safe Foundation
// class but not formally Sendable in the Swift overlay. The wrapping struct
// only reads/writes string-or-nil for one key, so the unchecked assertion is
// safe per UserDefaults's own concurrency contract.
//
// NOTE: this safety is IN-PROCESS only. UserDefaults serializes access within
// a process, but its backing plist is not written atomically across multiple
// PROCESSES sharing the same bundle id; concurrent writers in different
// processes can race. Logos is a single-process app, so this is not a concern
// here — but do not treat this type as a cross-process coordination point.
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
