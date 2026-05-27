import Foundation

@MainActor
enum FirstLaunchAccountImport {

    /// If no Logos accounts exist yet AND a system Claude Keychain entry
    /// exists, import that as the default account.
    ///
    /// E.2: reads from macOS Keychain (where modern Claude Code stores OAuth),
    /// not from a file. Result for existing claude users: open Logos and
    /// "just work" — their current login becomes the default account.
    static func runIfNeeded(into manager: AccountManager) {
        guard manager.accounts.isEmpty else { return }
        do {
            try manager.addByCapturingCurrent(label: "default")
            print("Logos: imported existing claude Keychain entry as 'default' account")
        } catch AccountManager.AddByCaptureError.noSystemCredentials {
            // User hasn't run `claude login` yet — they'll add accounts manually.
            print("Logos: no existing claude credentials to import")
        } catch {
            print("Logos: first-launch import failed: \(error)")
        }
    }
}
