import Foundation

@MainActor
enum FirstLaunchAccountImport {

    /// If no Logos accounts exist yet AND ~/.claude/.credentials.json exists,
    /// import that as the default account.
    ///
    /// Result for existing claude users: open Logos and "just work" — their
    /// current login becomes the default account automatically.
    static func runIfNeeded(into manager: AccountManager) {
        guard manager.accounts.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.claude/.credentials.json"
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        do {
            try manager.add(label: "default", credentials: data)
            print("Logos: imported existing ~/.claude/.credentials.json as 'default' account")
        } catch {
            print("Logos: failed to import existing credentials: \(error)")
        }
    }
}
