import Foundation
import Observation

@Observable
@MainActor
public final class AccountManager {

    @ObservationIgnored private let store: AccountCredentialStore
    @ObservationIgnored private let defaults: UserDefaults

    private enum DefaultsKey {
        static let accounts = "logos.accounts"
        static let activeId = "logos.accounts.activeId"
    }

    public private(set) var accounts: [Account] = []
    public private(set) var activeAccountId: String?

    public var active: Account? {
        guard let id = activeAccountId else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    public init(store: AccountCredentialStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        loadFromDefaults()
    }

    public func add(label: String, credentials: Data) throws {
        let trimmed = try Account.validate(label: label)
        if accounts.contains(where: { $0.label == trimmed }) {
            throw Account.ValidationError.duplicateLabel
        }
        let account = Account(label: trimmed)
        try store.save(accountId: account.id, credentials: credentials)
        accounts.append(account)
        if activeAccountId == nil {
            activeAccountId = account.id
        }
        persistToDefaults()
    }

    public func remove(accountId: String) throws {
        try store.delete(accountId: accountId)
        accounts.removeAll { $0.id == accountId }
        if activeAccountId == accountId {
            activeAccountId = accounts.first?.id
        }
        persistToDefaults()
    }

    public func setActive(_ accountId: String) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }
        activeAccountId = accountId
        persistToDefaults()
    }

    /// Ensure the per-account HOME tree exists on disk with current credentials
    /// written to .claude/.credentials.json. Call before spawning claude subprocess.
    public func materializeHomeTree(for account: Account) throws {
        let fm = FileManager.default
        let homePath = account.homeDirectoryPath
        let claudePath = "\(homePath)/.claude"
        try fm.createDirectory(atPath: claudePath, withIntermediateDirectories: true)
        let credentials = try store.load(accountId: account.id)
        let credsPath = "\(claudePath)/.credentials.json"
        try credentials.write(to: URL(fileURLWithPath: credsPath))
        // Restrict file permissions to user-only read (claude expects this)
        try fm.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credsPath
        )
    }

    private func loadFromDefaults() {
        if let data = defaults.data(forKey: DefaultsKey.accounts),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            self.accounts = decoded
        }
        self.activeAccountId = defaults.string(forKey: DefaultsKey.activeId)
        if active == nil, let first = accounts.first {
            self.activeAccountId = first.id
        }
    }

    private func persistToDefaults() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: DefaultsKey.accounts)
        }
        if let id = activeAccountId {
            defaults.set(id, forKey: DefaultsKey.activeId)
        } else {
            defaults.removeObject(forKey: DefaultsKey.activeId)
        }
    }
}
