import Foundation
import Observation

@Observable
@MainActor
public final class AccountManager {

    @ObservationIgnored private let store: AccountCredentialStore
    @ObservationIgnored private let systemBridge: SystemKeychainBridge
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

    public init(
        store: AccountCredentialStore,
        systemBridge: SystemKeychainBridge = RealSystemKeychainBridge(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.systemBridge = systemBridge
        self.defaults = defaults
        loadFromDefaults()
    }

    // MARK: - Add / Remove

    /// Original "add by raw blob" — kept for tests and explicit-import flows.
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
            // First account becomes active immediately. If there's no existing
            // system entry yet (e.g. cold start), we DON'T overwrite system —
            // we treat the just-added creds as the source of truth and write
            // them to system on next swap.
        }
        persistToDefaults()
    }

    /// E.2: Capture the CURRENT system Claude credentials and save as a new
    /// Logos account. This is the primary way to add accounts in v1.
    ///
    /// Flow: user runs `claude login` (or already logged in) → opens Logos →
    /// "Add account: work" → Logos reads system Keychain → saves as work.
    public func addByCapturingCurrent(label: String) throws {
        guard let data = try systemBridge.read() else {
            throw AddByCaptureError.noSystemCredentials
        }
        try add(label: label, credentials: data)
    }

    public enum AddByCaptureError: Error, Equatable {
        case noSystemCredentials
    }

    public func remove(accountId: String) throws {
        try store.delete(accountId: accountId)
        accounts.removeAll { $0.id == accountId }
        if activeAccountId == accountId {
            activeAccountId = accounts.first?.id
            // If a new account is now active, swap its creds into system.
            if let newActive = active {
                try? swapIntoSystem(account: newActive)
            }
        }
        persistToDefaults()
    }

    // MARK: - Switch active (the real swap!)

    /// E.2: Switching active = (1) optionally capture current system entry into
    /// the previously-active account (refresh stored creds) → (2) write target
    /// account's stored creds to system Keychain → (3) update local state.
    ///
    /// captureCurrent should be `true` in normal UI use (so we don't lose
    /// refreshed tokens), and `false` in tests where we want deterministic state.
    public func setActive(_ accountId: String, captureCurrent: Bool = true) {
        guard accounts.contains(where: { $0.id == accountId }) else { return }

        // Step 1: re-capture current creds into the previously-active account
        // (claude may have refreshed tokens since we last stored them).
        if captureCurrent,
           let prevId = activeAccountId,
           let currentSystemData = try? systemBridge.read() {
            try? store.save(accountId: prevId, credentials: currentSystemData)
        }

        // Step 2: write target account creds to system.
        if let target = accounts.first(where: { $0.id == accountId }) {
            try? swapIntoSystem(account: target)
        }

        // Step 3: update local state.
        activeAccountId = accountId
        persistToDefaults()
    }

    private func swapIntoSystem(account: Account) throws {
        let creds = try store.load(accountId: account.id)
        try systemBridge.write(creds)
    }

    /// Re-capture current system Claude credentials into the currently-active
    /// account. Useful if you suspect claude refreshed tokens recently.
    public func captureCurrentIntoActive() throws {
        guard let activeId = activeAccountId else { return }
        guard let data = try systemBridge.read() else { return }
        try store.save(accountId: activeId, credentials: data)
    }

    // MARK: - HOME tree (deprecated for credentials; kept for per-account history)

    /// Create per-account HOME tree at ~/.logos/accounts/<id>/.
    /// E.2: No longer writes .credentials.json (claude reads Keychain, not file).
    /// Still useful for per-account history isolation if HOME env override is used.
    public func materializeHomeTree(for account: Account) throws {
        let fm = FileManager.default
        let homePath = account.homeDirectoryPath
        let claudePath = "\(homePath)/.claude"
        try fm.createDirectory(atPath: claudePath, withIntermediateDirectories: true)
        // E.2: no longer writes .credentials.json. claude reads system Keychain.
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
