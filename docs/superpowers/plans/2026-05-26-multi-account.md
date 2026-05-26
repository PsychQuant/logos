# Sub-plan E — Multi-Account (Keychain + Quick Switcher)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let a Logos user manage multiple Claude accounts (personal, work, Pro tier, friend's) inside one app. Quick switcher via ⌘K (or click on status bar account name). Credentials stored in macOS Keychain. Each session's claude subprocess gets the right credentials injected via per-account `HOME` env tree.

**Why this is a killer feature:** Claude Code today has ONE credentials slot at `~/.claude/.credentials.json`. Switching accounts means `claude logout && claude login`, OAuth re-flow, slow + fragile. Many users have 2-4 accounts (free + Pro, personal + work, etc.). No existing tool solves this. This feature alone justifies installing Logos for those users.

**Architecture:**

```
   ~/Library/Keychain (macOS native, encrypted)
        │
        ▼
   ┌─────────────────────────┐
   │ AccountCredentialStore  │  (Keychain Services wrapper)
   │   - save(account, json) │
   │   - load(account) → json│
   │   - list() → [Account]  │
   │   - delete(account)     │
   └────────────┬────────────┘
                │
                ▼
   ┌─────────────────────────┐
   │ AccountManager           │  @Observable, exposed via Environment
   │   - accounts: [Account]  │
   │   - active: Account?     │
   │   - switch(to: Account)  │
   │   - import from default  │
   └────────────┬────────────┘
                │
                ▼ (when starting subprocess)
   ┌─────────────────────────┐
   │ ClaudeProcessConfig      │  MODIFY — accept Account, build HOME tree
   │   - homeDirectory: String│  (~/.logos/accounts/<id>/)
   │   - writes .credentials  │  before spawn
   └─────────────────────────┘

   Status bar 👤 personal  ←  click  →  AccountSwitcher sheet
                                          ┌─────────────────┐
                                          │ ○ personal      │
                                          │ ● work (active) │
                                          │ ○ friend        │
                                          │ ─────────────── │
                                          │ + Add account   │
                                          └─────────────────┘
```

**Tech Stack:** Swift 6, Observation, Keychain Services (`Security.framework`), SwiftUI sheets

**Prerequisites:**
- ✅ Sub-plan A (StatusBarViewModel.accountName exists)
- ✅ Sub-plan B (`ClaudeProcessConfig` exists with `environment`)
- ✅ Sub-plan D's lessons (auto-handle approves trust prompts that fire on first launch in a new HOME tree)
- The current `StatusBarViewModel.accountName` is a placeholder `"personal"` — this sub-plan wires the real source of truth

**Resolved/new design decisions:**
- **Storage mechanism**: macOS Keychain Services. Service name `"app.getlogos.logos"`, account name = user's chosen label (e.g., `"personal"`, `"work"`). Value = encrypted `.credentials.json` blob.
- **Subprocess credential injection**: option β from design § 8.4 — per-subprocess `HOME` env override. Each session subprocess runs with `HOME=~/.logos/accounts/<account-id>/` so claude reads its credentials from that tree.
- **Per-account HOME tree**: `~/.logos/accounts/<account-id>/`. Contains `.claude/.credentials.json` and is allowed to accumulate any other state claude writes (cache, config). Logos doesn't sync between trees; isolation is the point.
- **First launch import**: On first launch, if `~/.claude/.credentials.json` exists AND no Logos accounts exist yet, prompt user "Import existing claude login as default account?" → if yes, copy creds + name it (default name `"default"`).
- **Single-active model**: Exactly one account is "active" at any time. Each terminal session inherits the active account at spawn time. **Open question § 10.7** (session ↔ workspace) is NOT resolved by this sub-plan; sessions still bind to the active-at-spawn account.
- **Account labels**: user-editable strings. No validation beyond non-empty + max 30 chars + not duplicate.

**What this sub-plan does NOT include:**
- Per-workspace default accounts (e.g., always use "work" in ~/Developer/work-stuff) → sub-plan H
- OAuth flow in-app (user still does `claude login` in some terminal to get creds, then imports them) → could be vNext
- Account picker UI accessible via menu bar / global hotkey → vNext
- Cost tracking PER account (current cost is per-session) → vNext

---

## File Structure (delta from current main)

```
logos/
├── Sources/Logos/
│   ├── Models/
│   │   ├── Account.swift                                NEW
│   │   ├── AccountManager.swift                         NEW — @Observable
│   │   └── ClaudeProcessConfig.swift                    MODIFY — accept Account
│   ├── Services/                                        NEW directory
│   │   └── AccountCredentialStore.swift                 NEW — Keychain wrapper
│   ├── Views/
│   │   ├── AccountSwitcher/                             NEW directory
│   │   │   ├── AccountSwitcherSheet.swift               NEW — list + add/delete
│   │   │   └── AccountRow.swift                         NEW
│   │   ├── MainArea/
│   │   │   └── TerminalPaneView.swift                   MODIFY — read active account
│   │   └── StatusBar/
│   │       └── AccountStatusItem.swift                  MODIFY — click → sheet
│   └── App/
│       └── MainScene.swift                              MODIFY — inject AccountManager
├── Tests/LogosTests/
│   ├── AccountTests.swift                               NEW
│   ├── AccountManagerTests.swift                        NEW
│   └── AccountCredentialStoreTests.swift                NEW
```

---

## Task 1: Account model + tests

**Files:**
- Create: `Sources/Logos/Models/Account.swift`
- Test: `Tests/LogosTests/AccountTests.swift`

**Purpose:** Pure value type. `id` (stable, UUID-derived), `label` (user-visible), creation date.

- [ ] **Step 1: Write failing test**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("Account", .serialized)
struct AccountTests {

    @Test("account has id + label + creation date")
    func basicShape() {
        let acc = Account(id: "abc123", label: "personal")
        #expect(acc.id == "abc123")
        #expect(acc.label == "personal")
        #expect(acc.createdAt.timeIntervalSinceNow < 0)
    }

    @Test("home directory path is per-account")
    func homeDirectory() {
        let acc = Account(id: "abc", label: "x")
        #expect(acc.homeDirectoryPath.hasSuffix("/.logos/accounts/abc"))
    }

    @Test("label trims whitespace")
    func labelTrim() {
        let acc = Account(id: "x", label: "  work  ")
        #expect(acc.label == "work")
    }

    @Test("label rejects empty after trim")
    func labelEmpty() {
        #expect(throws: Account.ValidationError.emptyLabel) {
            _ = try Account.validate(label: "   ")
        }
    }

    @Test("label rejects > 30 chars")
    func labelTooLong() {
        let long = String(repeating: "a", count: 31)
        #expect(throws: Account.ValidationError.labelTooLong) {
            _ = try Account.validate(label: long)
        }
    }
}
```

- [ ] **Step 2: Implement `Account.swift`**

```swift
import Foundation

public struct Account: Identifiable, Hashable, Sendable, Codable {

    public let id: String  // stable account identifier, used as HOME directory name
    public let label: String  // user-visible name; editable
    public let createdAt: Date

    public init(id: String = UUID().uuidString, label: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespaces)
        self.createdAt = createdAt
    }

    public var homeDirectoryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.logos/accounts/\(id)"
    }

    public enum ValidationError: Error, Equatable {
        case emptyLabel
        case labelTooLong
        case duplicateLabel
    }

    /// Validate label only (duplicate-check requires AccountManager).
    public static func validate(label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw ValidationError.emptyLabel }
        if trimmed.count > 30 { throw ValidationError.labelTooLong }
        return trimmed
    }
}
```

- [ ] **Step 3: Run tests**

```bash
swift test --filter AccountTests
```

Expected: 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Models/Account.swift Tests/LogosTests/AccountTests.swift
git commit -m "feat(account): E-Task 1 — Account model + validation + 5 tests

Value type with id (stable HOME directory name), label (user-visible,
trimmed, 30 char max), createdAt. Validation throws emptyLabel /
labelTooLong / duplicateLabel cases.

homeDirectoryPath returns ~/.logos/accounts/<id>/ — the per-account
isolation tree where claude's credentials + cache + config live."
```

---

## Task 2: AccountCredentialStore (Keychain wrapper) + tests

**Files:**
- Create: `Sources/Logos/Services/AccountCredentialStore.swift`
- Test: `Tests/LogosTests/AccountCredentialStoreTests.swift`

**Purpose:** Keychain Services CRUD for credential blobs. Service-prefix = `"app.getlogos.logos.credentials"`. Each account has its credentials JSON stored encrypted at rest.

**Note:** Real Keychain access would interfere with tests. Tests use an in-memory mock conforming to the same protocol. Production code uses the real Keychain implementation.

- [ ] **Step 1: Write failing test**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("AccountCredentialStore", .serialized)
@MainActor
struct AccountCredentialStoreTests {

    @Test("save then load returns same blob")
    func saveLoadRoundtrip() throws {
        let store = InMemoryCredentialStore()
        let blob = Data("{\"token\":\"abc\"}".utf8)
        try store.save(accountId: "test", credentials: blob)
        let loaded = try store.load(accountId: "test")
        #expect(loaded == blob)
    }

    @Test("load missing account throws")
    func loadMissing() {
        let store = InMemoryCredentialStore()
        #expect(throws: AccountCredentialStoreError.notFound) {
            _ = try store.load(accountId: "nonexistent")
        }
    }

    @Test("delete removes entry")
    func deleteRemoves() throws {
        let store = InMemoryCredentialStore()
        try store.save(accountId: "x", credentials: Data("blob".utf8))
        try store.delete(accountId: "x")
        #expect(throws: AccountCredentialStoreError.notFound) {
            _ = try store.load(accountId: "x")
        }
    }

    @Test("list returns saved account ids")
    func list() throws {
        let store = InMemoryCredentialStore()
        try store.save(accountId: "a", credentials: Data("x".utf8))
        try store.save(accountId: "b", credentials: Data("y".utf8))
        let ids = try store.listAccountIds().sorted()
        #expect(ids == ["a", "b"])
    }

    @Test("overwrite same accountId updates blob")
    func overwrite() throws {
        let store = InMemoryCredentialStore()
        try store.save(accountId: "x", credentials: Data("v1".utf8))
        try store.save(accountId: "x", credentials: Data("v2".utf8))
        let loaded = try store.load(accountId: "x")
        #expect(loaded == Data("v2".utf8))
    }
}
```

- [ ] **Step 2: Implement protocol + Keychain + in-memory variants**

```swift
import Foundation
import Security

public enum AccountCredentialStoreError: Error, Equatable {
    case notFound
    case keychainError(OSStatus)
    case invalidData
}

@MainActor
public protocol AccountCredentialStore {
    func save(accountId: String, credentials: Data) throws
    func load(accountId: String) throws -> Data
    func delete(accountId: String) throws
    func listAccountIds() throws -> [String]
}

/// Production implementation backed by macOS Keychain.
@MainActor
public final class KeychainCredentialStore: AccountCredentialStore {

    private let service = "app.getlogos.logos.credentials"

    public init() {}

    public func save(accountId: String, credentials: Data) throws {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecValueData as String: credentials,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(attrs as CFDictionary)  // overwrite semantics
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AccountCredentialStoreError.keychainError(status)
        }
    }

    public func load(accountId: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw AccountCredentialStoreError.notFound
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AccountCredentialStoreError.keychainError(status)
        }
        return data
    }

    public func delete(accountId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw AccountCredentialStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw AccountCredentialStoreError.keychainError(status)
        }
    }

    public func listAccountIds() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw AccountCredentialStoreError.keychainError(status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// In-memory implementation for tests.
@MainActor
public final class InMemoryCredentialStore: AccountCredentialStore {

    private var storage: [String: Data] = [:]
    public init() {}

    public func save(accountId: String, credentials: Data) throws {
        storage[accountId] = credentials
    }

    public func load(accountId: String) throws -> Data {
        guard let data = storage[accountId] else {
            throw AccountCredentialStoreError.notFound
        }
        return data
    }

    public func delete(accountId: String) throws {
        guard storage.removeValue(forKey: accountId) != nil else {
            throw AccountCredentialStoreError.notFound
        }
    }

    public func listAccountIds() throws -> [String] {
        Array(storage.keys)
    }
}
```

- [ ] **Step 3: Run tests**

```bash
swift test --filter AccountCredentialStoreTests
```

Expected: 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Services/AccountCredentialStore.swift \
        Tests/LogosTests/AccountCredentialStoreTests.swift
git commit -m "feat(account): E-Task 2 — AccountCredentialStore (Keychain + in-memory)

Protocol + 2 implementations. KeychainCredentialStore uses macOS
Security.framework SecItemAdd/Copy/Delete with service prefix
'app.getlogos.logos.credentials'. Stores per-account credential
blob keyed by accountId. AfterFirstUnlockThisDeviceOnly accessibility.

InMemoryCredentialStore for tests — same interface, dictionary-backed.

5 tests passing on in-memory variant (real Keychain access in
production code only)."
```

---

## Task 3: AccountManager (@Observable, central state) + tests

**Files:**
- Create: `Sources/Logos/Models/AccountManager.swift`
- Test: `Tests/LogosTests/AccountManagerTests.swift`

**Purpose:** Holds the account list + active selection. Persists list metadata (labels) separately from credentials (Keychain handles those). Survives app relaunches via UserDefaults for the metadata list + Keychain for the credential blobs.

- [ ] **Step 1: Write failing test**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("AccountManager", .serialized)
@MainActor
struct AccountManagerTests {

    @Test("starts empty")
    func startsEmpty() {
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            defaults: makeTransientDefaults()
        )
        #expect(mgr.accounts.isEmpty)
        #expect(mgr.active == nil)
    }

    @Test("add account stores label + writes creds")
    func addAccount() throws {
        let store = InMemoryCredentialStore()
        let mgr = AccountManager(store: store, defaults: makeTransientDefaults())
        try mgr.add(label: "personal", credentials: Data("{}".utf8))
        #expect(mgr.accounts.count == 1)
        #expect(mgr.accounts[0].label == "personal")
        let firstId = mgr.accounts[0].id
        let blob = try store.load(accountId: firstId)
        #expect(blob == Data("{}".utf8))
    }

    @Test("first added becomes active by default")
    func firstActive() throws {
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            defaults: makeTransientDefaults()
        )
        try mgr.add(label: "p", credentials: Data())
        #expect(mgr.active?.label == "p")
    }

    @Test("switch active changes selection")
    func switchActive() throws {
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            defaults: makeTransientDefaults()
        )
        try mgr.add(label: "a", credentials: Data())
        try mgr.add(label: "b", credentials: Data())
        let bAccount = mgr.accounts.first(where: { $0.label == "b" })!
        mgr.setActive(bAccount.id)
        #expect(mgr.active?.label == "b")
    }

    @Test("duplicate label rejected")
    func duplicateLabel() throws {
        let mgr = AccountManager(
            store: InMemoryCredentialStore(),
            defaults: makeTransientDefaults()
        )
        try mgr.add(label: "x", credentials: Data())
        #expect(throws: Account.ValidationError.duplicateLabel) {
            try mgr.add(label: "x", credentials: Data())
        }
    }

    @Test("remove account also removes creds + reassigns active")
    func removeAccount() throws {
        let store = InMemoryCredentialStore()
        let mgr = AccountManager(store: store, defaults: makeTransientDefaults())
        try mgr.add(label: "a", credentials: Data())
        try mgr.add(label: "b", credentials: Data())
        let firstId = mgr.accounts[0].id
        try mgr.remove(accountId: firstId)
        #expect(mgr.accounts.count == 1)
        #expect(mgr.active?.label == "b")
        // Credentials should be gone too
        #expect(throws: AccountCredentialStoreError.notFound) {
            _ = try store.load(accountId: firstId)
        }
    }

    @Test("active persists across new manager init with same defaults")
    func activePersists() throws {
        let defaults = makeTransientDefaults()
        let mgr1 = AccountManager(store: InMemoryCredentialStore(), defaults: defaults)
        try mgr1.add(label: "a", credentials: Data())
        try mgr1.add(label: "b", credentials: Data())
        let bId = mgr1.accounts[1].id
        mgr1.setActive(bId)

        // New manager with same defaults should restore active selection
        let mgr2 = AccountManager(store: InMemoryCredentialStore(), defaults: defaults)
        // We expect at least the active ID to be restored
        // (account list itself is rebuilt from UserDefaults via codable storage)
        #expect(mgr2.activeAccountId == bId)
    }

    // Helper
    private func makeTransientDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LogosE_\(UUID().uuidString)")!
    }
}
```

- [ ] **Step 2: Implement `AccountManager`**

```swift
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
```

- [ ] **Step 3: Run tests**

```bash
swift test --filter AccountManagerTests
```

Expected: 7 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Models/AccountManager.swift \
        Tests/LogosTests/AccountManagerTests.swift
git commit -m "feat(account): E-Task 3 — AccountManager @Observable + 7 tests

Holds account list + active selection. Persists metadata to
UserDefaults (Codable Account array) and credentials to injected
AccountCredentialStore (Keychain in prod, InMemory in tests).
Active selection survives relaunch.

API: add(label:credentials:), remove(accountId:), setActive(_:).
Duplicate-label rejection. Auto-promote first account to active.
On remove of active, reassign to first remaining."
```

---

## Task 4: Wire ClaudeProcessConfig to use active account's HOME

**Files:**
- Modify: `Sources/Logos/Models/ClaudeProcessConfig.swift`
- Modify: `Tests/LogosTests/ClaudeProcessConfigTests.swift`

**Purpose:** When spawning claude subprocess, set `HOME=<account.homeDirectoryPath>` so claude reads from per-account credential tree. Also ensure the tree exists (mkdir + write credentials).

- [ ] **Step 1: Update `ClaudeProcessConfig` to accept optional account**

```swift
import Foundation

public struct ClaudeProcessConfig: Sendable {

    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?
    public let account: Account?

    public init(
        executablePath: String,
        account: Account? = nil,
        extraArgs: [String] = [],
        workingDirectory: String? = nil
    ) {
        self.executablePath = executablePath
        self.account = account
        // Sub-plan D: auto-handle replaces --dangerously-skip-permissions
        self.arguments = extraArgs

        self.workingDirectory = workingDirectory

        // Inherit user environment, force TERM, override HOME if account specified
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        if let account = account {
            env["HOME"] = account.homeDirectoryPath
        }
        self.environment = env
    }
}
```

- [ ] **Step 2: Update tests**

Modify `ClaudeProcessConfigTests.swift` to add account-specific tests:

```swift
// Add to existing test suite:

@Test("HOME overridden when account provided")
func homeOverride() {
    let account = Account(id: "test-acc", label: "work")
    let cfg = ClaudeProcessConfig(
        executablePath: "/usr/local/bin/claude",
        account: account
    )
    #expect(cfg.environment["HOME"] == account.homeDirectoryPath)
    #expect(cfg.environment["HOME"]?.hasSuffix("/.logos/accounts/test-acc") == true)
}

@Test("HOME unchanged when no account")
func homeNoAccount() {
    let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
    let processHome = ProcessInfo.processInfo.environment["HOME"]
    #expect(cfg.environment["HOME"] == processHome)
}
```

- [ ] **Step 3: Add credential-tree materialization helper**

```swift
// Add to AccountManager.swift:

/// Ensure the per-account HOME tree exists on disk with current credentials
/// written to .claude/.credentials.json. Call before spawning claude.
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
```

Add tests for `materializeHomeTree`:

```swift
@Test("materializeHomeTree creates ~/.logos/accounts/<id>/.claude/.credentials.json")
func materializeHomeTreeCreates() throws {
    let store = InMemoryCredentialStore()
    let mgr = AccountManager(store: store, defaults: makeTransientDefaults())
    try mgr.add(label: "tmpacct", credentials: Data("{\"k\":\"v\"}".utf8))
    let account = mgr.accounts[0]
    try mgr.materializeHomeTree(for: account)
    let credsPath = "\(account.homeDirectoryPath)/.claude/.credentials.json"
    #expect(FileManager.default.fileExists(atPath: credsPath))
    let loaded = try Data(contentsOf: URL(fileURLWithPath: credsPath))
    #expect(loaded == Data("{\"k\":\"v\"}".utf8))
    // Cleanup
    try? FileManager.default.removeItem(atPath: account.homeDirectoryPath)
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter ClaudeProcessConfigTests
swift test --filter AccountManagerTests
```

Expected: ClaudeProcessConfigTests now has 7 tests (5 prior + 2 new); AccountManagerTests has 8 (7 prior + 1 new).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(account): E-Task 4 — wire ClaudeProcessConfig to per-account HOME

ClaudeProcessConfig.init now accepts Account? — when provided, sets
HOME env var to account.homeDirectoryPath. claude subprocess reads
its credentials from ~/.logos/accounts/<id>/.claude/.credentials.json
instead of ~/.claude/.

AccountManager.materializeHomeTree(for:) creates the directory tree
and writes credentials with 0o600 perms (claude expects).

2 new ClaudeProcessConfig tests + 1 new AccountManager test."
```

---

## Task 5: TerminalPaneView spawns claude with active account

**Files:**
- Modify: `Sources/Logos/Views/MainArea/TerminalPaneView.swift`
- Modify: `Sources/Logos/Terminal/SwiftTermView.swift` — coordinator materializes HOME tree before startProcess

- [ ] **Step 1: Update `TerminalPaneView`**

```swift
import SwiftUI

struct TerminalPaneView: View {
    @Environment(TerminalConfig.self) private var config
    @Environment(AutoHandleEngine.self) private var engine
    @Environment(AccountManager.self) private var accountMgr

    var body: some View {
        Group {
            if let active = accountMgr.active,
               let claudePath = config.resolvedClaudePath {
                let processConfig = ClaudeProcessConfig(
                    executablePath: claudePath,
                    account: active
                )
                SwiftTermView(
                    config: config,
                    processConfig: processConfig,
                    engine: engine,
                    accountManager: accountMgr
                )
                .background(Color.black)
                .id(active.id)  // Force view recreation on account switch
            } else if accountMgr.active == nil {
                NoActiveAccountBanner()
            } else {
                ClaudeNotFoundBanner()
            }
        }
    }
}

private struct NoActiveAccountBanner: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("No active account")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Add an account from the status bar (👤) to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}
```

- [ ] **Step 2: Update `SwiftTermView` Coordinator to materialize HOME before startProcess**

In `SwiftTermView.swift`, modify `startIfNeeded`:

```swift
func startIfNeeded(_ view: TeedLocalProcessTerminalView) {
    guard !hasStarted else { return }
    hasStarted = true
    self.view = view

    // Materialize HOME tree for active account before spawn
    if let account = processConfig.account {
        do {
            try accountManager?.materializeHomeTree(for: account)
        } catch {
            // Could not write credentials — claude will likely fail to auth.
            // For v1, log and let claude show its own auth-failed message.
            // Future (sub-plan H): show in-app banner.
            print("Logos: failed to materialize HOME for account \(account.id): \(error)")
        }
    }

    view.startProcess(
        executable: processConfig.executablePath,
        args: processConfig.arguments,
        environment: processConfig.environment.map { "\($0.key)=\($0.value)" },
        execName: nil,
        currentDirectory: processConfig.workingDirectory
    )
}
```

Update `SwiftTermView` to accept and pass through `accountManager`:

```swift
struct SwiftTermView: NSViewRepresentable {
    let config: TerminalConfig
    let processConfig: ClaudeProcessConfig
    let engine: AutoHandleEngine
    let accountManager: AccountManager

    func makeCoordinator() -> Coordinator {
        Coordinator(
            processConfig: processConfig,
            engine: engine,
            accountManager: accountManager
        )
    }
    // ... rest unchanged ...
}
```

Coordinator init updated accordingly.

- [ ] **Step 3: Build + run all tests**

```bash
swift build
swift test
```

Expected: 47 cumulative tests (40 prior + 5 Account + 5 Store + 7 Manager + extras). Actual count depends on exact additions; verify >= 40.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(account): E-Task 5 — TerminalPaneView spawns claude with active account

TerminalPaneView now reads AccountManager from environment. If no
active account, shows NoActiveAccountBanner directing user to add one.
If active exists, passes Account into ClaudeProcessConfig + injects
AccountManager into SwiftTermView's coordinator.

Coordinator.startIfNeeded materializes the per-account HOME tree
(writes credentials with 0o600 perms) BEFORE startProcess, so claude
finds credentials in HOME/.claude/.credentials.json on first read.

.id(active.id) modifier forces SwiftTermView recreation when user
switches active account — clean process restart, no stale state."
```

---

## Task 6: AccountSwitcherSheet UI + status bar click

**Files:**
- Create: `Sources/Logos/Views/AccountSwitcher/AccountSwitcherSheet.swift`
- Create: `Sources/Logos/Views/AccountSwitcher/AccountRow.swift`
- Modify: `Sources/Logos/Views/StatusBar/AccountStatusItem.swift` — open sheet on click

- [ ] **Step 1: Create `AccountRow.swift`**

```swift
import SwiftUI

struct AccountRow: View {
    let account: Account
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(account.label)
                .font(.body)
                .fontWeight(isActive ? .semibold : .regular)
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .opacity(0.6)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}
```

- [ ] **Step 2: Create `AccountSwitcherSheet.swift`**

```swift
import SwiftUI

struct AccountSwitcherSheet: View {
    @Environment(AccountManager.self) private var mgr
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSheet = false
    @State private var newLabel = ""
    @State private var newCredentialsPath = ""
    @State private var addError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Accounts")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            if mgr.accounts.isEmpty {
                VStack(spacing: 8) {
                    Text("No accounts yet")
                        .foregroundStyle(.secondary)
                    Text("Add your first account below.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(mgr.accounts) { acc in
                            AccountRow(
                                account: acc,
                                isActive: acc.id == mgr.activeAccountId,
                                onSelect: { mgr.setActive(acc.id) },
                                onDelete: { try? mgr.remove(accountId: acc.id) }
                            )
                            Divider()
                        }
                    }
                }
            }

            Divider()

            Button(action: { showAddSheet = true }) {
                Label("Add account", systemImage: "plus.circle.fill")
                    .padding(.vertical, 4)
            }
            .padding(8)
        }
        .frame(width: 360, height: 360)
        .sheet(isPresented: $showAddSheet) {
            AddAccountForm(
                label: $newLabel,
                credentialsPath: $newCredentialsPath,
                error: $addError,
                onSave: { addAccount() },
                onCancel: { dismissAddSheet() }
            )
        }
    }

    private func addAccount() {
        addError = nil
        let credsURL = URL(fileURLWithPath: NSString(string: newCredentialsPath).expandingTildeInPath)
        guard let data = try? Data(contentsOf: credsURL) else {
            addError = "Could not read credentials file at that path."
            return
        }
        do {
            try mgr.add(label: newLabel, credentials: data)
            dismissAddSheet()
        } catch {
            addError = "\(error)"
        }
    }

    private func dismissAddSheet() {
        newLabel = ""
        newCredentialsPath = ""
        addError = nil
        showAddSheet = false
    }
}

private struct AddAccountForm: View {
    @Binding var label: String
    @Binding var credentialsPath: String
    @Binding var error: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add account")
                .font(.title3)
                .fontWeight(.semibold)
            TextField("Label (e.g. work)", text: $label)
                .textFieldStyle(.roundedBorder)
            TextField("Path to .credentials.json", text: $credentialsPath)
                .textFieldStyle(.roundedBorder)
                .help("Run `claude login` in a terminal first, then point here to ~/.claude/.credentials.json")
            if let err = error {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.isEmpty || credentialsPath.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
```

- [ ] **Step 3: Update `AccountStatusItem` to open sheet**

```swift
import SwiftUI

struct AccountStatusItem: View {
    @Environment(AccountManager.self) private var mgr
    @State private var showSwitcher = false

    var body: some View {
        Button(action: { showSwitcher = true }) {
            Label(mgr.active?.label ?? "no account", systemImage: "person.crop.circle")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Click to switch / manage accounts (⌘K)")
        .keyboardShortcut("k", modifiers: .command)
        .sheet(isPresented: $showSwitcher) {
            AccountSwitcherSheet()
        }
    }
}
```

- [ ] **Step 4: Build**

```bash
swift build
```

Expected: SUCCESS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(account): E-Task 6 — AccountSwitcherSheet UI + status bar click

AccountSwitcherSheet (360x360): list of accounts with radio-button
active indicator + trash button, 'Add account' bottom action. Add sheet
asks for label + path to existing .credentials.json (user runs 'claude
login' separately, then imports the file path).

AccountStatusItem now a Button — click or ⌘K opens switcher sheet.
Shows active account label OR 'no account' if none yet.

No in-app OAuth flow — that's vNext. Current flow: user runs
'claude login' in terminal, then imports."
```

---

## Task 7: MainScene wires AccountManager + first-launch import

**Files:**
- Modify: `Sources/Logos/App/MainScene.swift`
- Create: `Sources/Logos/App/FirstLaunchAccountImport.swift`

- [ ] **Step 1: Create `FirstLaunchAccountImport.swift`**

```swift
import Foundation

@MainActor
enum FirstLaunchAccountImport {

    /// If no Logos accounts exist yet AND ~/.claude/.credentials.json exists,
    /// import that as the default account.
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
```

- [ ] **Step 2: Update `MainScene.swift`**

```swift
import SwiftUI

struct MainScene: Scene {

    @State private var layout = WindowLayoutState()
    @State private var activityBar = ActivityBarSelection()
    @State private var statusBar = StatusBarViewModel()
    @State private var terminalConfig = TerminalConfig()
    @State private var autoHandleEngine = AutoHandleEngine()
    @State private var accountManager = AccountManager(store: KeychainCredentialStore())

    var body: some Scene {
        WindowGroup("Logos") {
            MainView()
                .environment(layout)
                .environment(activityBar)
                .environment(statusBar)
                .environment(terminalConfig)
                .environment(autoHandleEngine)
                .environment(accountManager)
                .frame(
                    minWidth: 900,
                    idealWidth: 1400,
                    minHeight: 600,
                    idealHeight: 900
                )
                .onAppear {
                    FirstLaunchAccountImport.runIfNeeded(into: accountManager)
                }
        }
        .windowResizability(.contentSize)
    }
}
```

- [ ] **Step 3: Build + final regression**

```bash
swift build
swift test
```

Expected: build succeeds, all tests pass (cumulative ~50).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(account): E-Task 7 — MainScene injects AccountManager + first-launch import

MainScene holds @State AccountManager(store: KeychainCredentialStore()),
injects via environment. .onAppear runs FirstLaunchAccountImport which
imports ~/.claude/.credentials.json as 'default' account if no Logos
accounts exist yet.

Result: existing claude users open Logos and 'just work' — their current
login becomes the default account automatically."
```

---

## Task 8: Live smoke + screenshot + README

**Files:**
- README.md
- Optional: docs/screenshots/account-switcher.png

- [ ] **Step 1: Live smoke**

Launch app, observe:
- Status bar shows account label (imported as "default" or whatever your existing claude login was)
- Click status bar account → switcher sheet opens with one row
- Click "Add account" → form opens (you can test by pointing at the same credentials.json with a different label, e.g., "work-copy")
- Switch active → terminal pane recreates with new account
- Verify ~/.logos/accounts/<id>/.claude/.credentials.json exists for the active account
- claude subprocess should use the imported account's creds (no re-login prompt)

- [ ] **Step 2: Screenshot**

```bash
# Launch + screenshot via CGWindowID as in B-Task 8 / D-Task 6
```

Save to `docs/screenshots/account-switcher.png`.

- [ ] **Step 3: README update**

Add to repo status:

```markdown
**Sub-plan E — Multi-account: COMPLETE ✅**
- Keychain-backed credentials (one entry per account)
- ⌘K or status-bar click → AccountSwitcherSheet
- First-launch auto-imports ~/.claude/.credentials.json as 'default'
- Per-account HOME tree at ~/.logos/accounts/<id>/ — claude reads its own creds
- Switch active → SwiftTermView recreates with new account, clean process restart
```

- [ ] **Step 4: Final commit + push**

```bash
git add -A
git commit -m "feat(account): E-Task 8 — sub-plan E complete, multi-account live

Live smoke verified: first-launch import, switcher sheet UI,
active-account switch triggers SwiftTermView recreation with new
HOME env injection.

Logos's #2 killer feature delivered: power users with multiple
claude accounts can switch in 1 click instead of logout/login cycle."
git push
```

---

## Self-review checklist

1. **Spec coverage**: 8 tasks cover Account model + Keychain store + AccountManager + ClaudeProcessConfig wiring + TerminalPaneView integration + Switcher UI + first-launch import + smoke. Maps to design § 7.3 + § 8.4. ✅
2. **Placeholders**: All tasks have concrete code + test code + commit messages. The "user runs claude login separately" is documented in UI help text — not a placeholder, it's the explicit v1 flow. ✅
3. **Type consistency**: `Account`, `AccountCredentialStore`, `AccountManager`, `ClaudeProcessConfig.account` consistent across tasks. ✅
4. **Known risks**:
   - Keychain prompt on first save: macOS may prompt user "Allow Logos to access Keychain?" — happens once, then granted. Mitigation: documented in UI add-account form.
   - File permissions: claude expects `.credentials.json` to be 0o600. Materializer sets this. If claude logs auth errors, check perms.
   - First-launch import edge case: if `~/.claude/.credentials.json` is malformed, import will save garbage. Future hardening: validate JSON shape before save.
   - HOME override side effects: claude may write OTHER files into HOME (cache, config). Per-account tree accumulates these. Disk usage grows. Acceptable for v1; cleanup utility deferred.
   - Account switch mid-conversation: changing active account kills current claude subprocess (SwiftTermView recreates). User loses session state. UI should warn before switch. **Mitigation deferred — log as known UX rough edge.**

---

## Done. Next:
- Sub-plan F (file explorer + viewer) — independent of D/E
- Sub-plan G (PDF live render) — depends on F's file viewer pane
- Sub-plan C.2 (frame-rate renderer) — the moat begins
- Sub-plan H (Settings UI) — wires per-account default workspaces, per-rule auto-handle config, font/theme settings
