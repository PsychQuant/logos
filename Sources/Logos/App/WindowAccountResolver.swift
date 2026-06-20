import LogoSwitch

/// Pure resolution of a window's effective account (#42).
///
/// No SwiftUI, no `@MainActor` state — a plain value-in/value-out enum (mirroring
/// `MainScene.resolveLaunchWorkspace`) so the seeding precedence + graceful-degrade
/// behavior is directly testable under `swift test` (the unit gate), instead of
/// living only inside a SwiftUI view body that a bare `swift test` can't exercise.
enum WindowAccountResolver {

    /// Seed a freshly-opened (or scene-restored) window's account id. Precedence:
    /// 1. `presented` — the value the window was opened/restored with, if it still
    ///    names a live account;
    /// 2. `defaultId` — the global new-window default (`AccountManager.activeAccountId`),
    ///    if live;
    /// 3. the first account;
    /// 4. `nil` — no accounts → the pane shows `NoActiveAccountBanner`.
    ///
    /// An id that no longer names a live account (deleted, or a stale restored
    /// value) is never adopted — that is the graceful-degrade contract.
    static func seed(presented: String?, default defaultId: String?, accounts: [Account]) -> String? {
        if let presented, accounts.contains(where: { $0.id == presented }) { return presented }
        if let defaultId, accounts.contains(where: { $0.id == defaultId }) { return defaultId }
        return accounts.first?.id
    }

    /// Resolve the live `Account` a window currently shows. A `nil` selection — or a
    /// selection naming a since-deleted account — both resolve to `nil`, so the pane
    /// degrades to `NoActiveAccountBanner` rather than spawning claude into a phantom
    /// `CLAUDE_CONFIG_DIR`.
    static func resolve(selected: String?, accounts: [Account]) -> Account? {
        guard let selected else { return nil }
        return accounts.first { $0.id == selected }
    }
}
