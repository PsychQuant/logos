# account-credential-isolation Specification

## Purpose

TBD - created by archiving change 'account-credential-isolation'. Update Purpose after archive.

## Requirements

### Requirement: Account switching performs no system Keychain write

Switching the active account (`AccountManager.setActive`) and removing an account (`AccountManager.remove`) SHALL NOT write to or delete from the shared system Keychain entry (`service="Claude Code-credentials"`). Switching SHALL change only Logos-local active state and the per-spawn `CLAUDE_CONFIG_DIR`. This removes the cross-identity `SecItem` write that can trigger the macOS reset dialog.

#### Scenario: Switching active account does not write the Keychain

- **WHEN** the user selects a different account in the account switcher
- **THEN** no `SecItemAdd`, `SecItemUpdate`, or `SecItemDelete` is performed against the shared `Claude Code-credentials` entry
- **AND** no macOS Keychain consent or reset dialog is surfaced by the switch

#### Scenario: Removing an account does not write the Keychain

- **WHEN** the user removes an account (including the active one)
- **THEN** the shared system Keychain entry is not written or deleted by Logos


<!-- @trace
source: account-credential-isolation
updated: 2026-05-29
code:
  - CHANGELOG.md
  - Sources/Logos/Views/AccountSwitcher/AccountSwitcherSheet.swift
  - Tests/LogosTests/SystemKeychainBridgeTests.swift
  - Tests/LogosTests/AccountManagerTests.swift
  - Sources/Logos/Models/AccountManager.swift
  - README.md
  - Sources/Logos/Models/ClaudeProcessConfig.swift
  - Sources/Logos/Services/SystemKeychainBridge.swift
  - Sources/Logos/Views/AccountSwitcher/AccountRow.swift
  - .spectra.yaml
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/AccountCredentialIsolationTests.swift
  - Sources/Logos/Models/Account.swift
-->

---
### Requirement: Each account spawns claude with an isolated config directory

When Logos spawns `claude` for a specific account, the spawn environment SHALL set `CLAUDE_CONFIG_DIR` to that account's stable per-account config directory, so claude reads and writes its own per-directory Keychain item (`Claude Code-credentials-<hash>`, where `<hash>` is the first 8 hex characters of `sha256` over the NFC-normalized config-directory string) rather than the shared bare entry. claude derives the credential service name from its secure-storage config directory, which is resolved from `CLAUDE_SECURESTORAGE_CONFIG_DIR` when that variable is defined and falls back to `CLAUDE_CONFIG_DIR` only when it is undefined; a defined-but-empty `CLAUDE_SECURESTORAGE_CONFIG_DIR` forces claude back to the bare service name and defeats isolation. Therefore the spawn environment SHALL set `CLAUDE_SECURESTORAGE_CONFIG_DIR` to the same per-account config directory as `CLAUDE_CONFIG_DIR`, and SHALL NOT pass `CLAUDE_SECURESTORAGE_CONFIG_DIR` as an empty string (any empty value inherited from the parent environment SHALL be overwritten or removed).

#### Scenario: Account-scoped spawn sets CLAUDE_CONFIG_DIR

- **WHEN** Logos builds the process environment for an account-scoped `claude` spawn
- **THEN** `CLAUDE_CONFIG_DIR` equals that account's config directory path
- **AND** `CLAUDE_SECURESTORAGE_CONFIG_DIR` equals the same account config directory path
- **AND** `CLAUDE_SECURESTORAGE_CONFIG_DIR` is never present as an empty string

#### Scenario: Distinct accounts get distinct config directories

- **WHEN** two distinct accounts each build a spawn environment
- **THEN** their `CLAUDE_CONFIG_DIR` values differ, yielding distinct claude credential items

##### Example: per-account config dirs

| Account id | CLAUDE_CONFIG_DIR | Resulting claude Keychain service |
| ---------- | ----------------- | --------------------------------- |
| work       | ~/.logos/accounts/work/.claude | Claude Code-credentials-<hash(work)> |
| personal   | ~/.logos/accounts/personal/.claude | Claude Code-credentials-<hash(personal)> |


<!-- @trace
source: account-credential-isolation
updated: 2026-05-29
code:
  - CHANGELOG.md
  - Sources/Logos/Views/AccountSwitcher/AccountSwitcherSheet.swift
  - Tests/LogosTests/SystemKeychainBridgeTests.swift
  - Tests/LogosTests/AccountManagerTests.swift
  - Sources/Logos/Models/AccountManager.swift
  - README.md
  - Sources/Logos/Models/ClaudeProcessConfig.swift
  - Sources/Logos/Services/SystemKeychainBridge.swift
  - Sources/Logos/Views/AccountSwitcher/AccountRow.swift
  - .spectra.yaml
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/AccountCredentialIsolationTests.swift
  - Sources/Logos/Models/Account.swift
-->

---
### Requirement: The shared bare Keychain entry is never mutated

Logos SHALL NOT delete or overwrite the bare `Claude Code-credentials` entry under any account operation, usage refresh, or migration step, and this mutation ban SHALL extend to every target in the merged package (including the read-only usage target). The bare entry belongs to the user's plain-terminal `claude login` and mutating it risks a login-keychain cascade. Within the Logos app, any read of the bare entry SHALL be limited to two read-only cases: (a) an explicit, user-initiated migration check, and (b) the Logos usage window resolving plan usage for the system-default account, whose claude credential is the bare entry because it reuses `~/.claude`. The Logos usage window SHALL read the bare entry only for the system-default account's row; for every isolated (convention) account it SHALL use that account's hash-suffixed per-directory service name and SHALL NOT read the bare entry. These reads are read-only and SHALL NOT relax the mutation ban above. Outside the Logos app, read-only access to the bare entry SHALL be limited to the standalone viewer executable reading it through the read-only credentials reader during a user-initiated usage refresh.

#### Scenario: Plain-terminal claude is unaffected

- **WHEN** any Logos account operation (add, switch, remove, migrate) completes
- **THEN** the bare `Claude Code-credentials` entry is byte-identical to its pre-operation value
- **AND** a `claude` invocation run outside Logos continues to authenticate

#### Scenario: Usage refresh leaves the bare entry untouched

- **WHEN** a usage refresh completes in the Logos usage window or the standalone viewer
- **THEN** the bare `Claude Code-credentials` entry is byte-identical to its pre-refresh value

#### Scenario: Usage window reads bare only for the system-default account

- **WHEN** the Logos usage window refreshes
- **THEN** the system-default account's row resolves credentials via the bare `Claude Code-credentials` service name, read-only
- **AND** every isolated (convention) account's row resolves credentials via its hash-suffixed per-directory service name
- **AND** no Keychain read performs an add, update, or delete on any entry

##### Example: service name per usage row

| Account kind | Config dir | Keychain service (read-only) |
| ------------ | ---------- | ---------------------------- |
| system-default (Main) | ~/.claude | Claude Code-credentials |
| isolated (work) | ~/.logos/accounts/work/.claude | Claude Code-credentials-<first 8 hex of sha256(path)> |

---
### Requirement: A missing per-account credential is surfaced as needs-reauth

Logos SHALL determine the needs-reauth state using only promptless signals and SHALL NOT probe the system Keychain for credential presence (a cross-identity Keychain read can surface an access prompt and re-introduces the keychain coupling this change removes). An account is treated as authenticated when EITHER Logos's own per-account authenticated flag is set (recorded when the user completes authentication for that account) OR a `.credentials.json` file exists inside that account's config directory (claude's file-based credential, a promptless filesystem signal). When neither holds, Logos SHALL surface that account as requiring re-authentication (a visible needs-reauth state) rather than spawning a silently unauthenticated session. Re-authentication is performed by running `claude login` under that account's config directory; Logos SHALL NOT write the credential itself. The flag is best-effort and MAY drift if the user authenticates or logs out outside Logos; this is acceptable for a surfaced indicator.

#### Scenario: Account without its own credential is flagged

- **WHEN** an account has no Logos authenticated flag set AND no `.credentials.json` file exists in that account's config directory
- **THEN** the account is shown in a needs-reauth state in the switcher
- **AND** selecting it directs the user to authenticate via `claude login` under its config directory

#### Scenario: Either credential signal clears needs-reauth

- **WHEN** an account has its Logos authenticated flag set, OR a `.credentials.json` file exists in its config directory
- **THEN** the account is not shown in a needs-reauth state
- **AND** Logos performs no system Keychain read while making this determination


<!-- @trace
source: account-credential-isolation
updated: 2026-05-29
code:
  - CHANGELOG.md
  - Sources/Logos/Views/AccountSwitcher/AccountSwitcherSheet.swift
  - Tests/LogosTests/SystemKeychainBridgeTests.swift
  - Tests/LogosTests/AccountManagerTests.swift
  - Sources/Logos/Models/AccountManager.swift
  - README.md
  - Sources/Logos/Models/ClaudeProcessConfig.swift
  - Sources/Logos/Services/SystemKeychainBridge.swift
  - Sources/Logos/Views/AccountSwitcher/AccountRow.swift
  - .spectra.yaml
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/AccountCredentialIsolationTests.swift
  - Sources/Logos/Models/Account.swift
-->

---
### Requirement: Existing accounts migrate non-destructively

On upgrade to the isolated-credential model, existing accounts SHALL be migrated without Logos writing any Keychain credential. Each existing account SHALL be marked needs-reauth unless its per-directory item already exists, and the previously-active account's bare entry SHALL be left in place so it keeps working until the user re-authenticates.

#### Scenario: Upgrade marks accounts for re-auth without writing credentials

- **WHEN** the user first launches the build that introduces credential isolation
- **THEN** each account lacking a per-directory credential item is marked needs-reauth
- **AND** no Keychain credential is written by Logos during migration
- **AND** the bare `Claude Code-credentials` entry is left untouched

<!-- @trace
source: account-credential-isolation
updated: 2026-05-29
code:
  - CHANGELOG.md
  - Sources/Logos/Views/AccountSwitcher/AccountSwitcherSheet.swift
  - Tests/LogosTests/SystemKeychainBridgeTests.swift
  - Tests/LogosTests/AccountManagerTests.swift
  - Sources/Logos/Models/AccountManager.swift
  - README.md
  - Sources/Logos/Models/ClaudeProcessConfig.swift
  - Sources/Logos/Services/SystemKeychainBridge.swift
  - Sources/Logos/Views/AccountSwitcher/AccountRow.swift
  - .spectra.yaml
  - Sources/Logos/App/MainScene.swift
  - Tests/LogosTests/AccountCredentialIsolationTests.swift
  - Sources/Logos/Models/Account.swift
-->

---
### Requirement: Security framework usage is confined to the audited usage target

Within the merged package, the Security framework SHALL be importable only by the LogosUsage target. The sources of LogoSwitch, LogosAccounts, and the Logos app target SHALL pass the red-line forbidden-token scan (Security import, SecItem tokens, find-generic-password, add-generic-password, and the security(1) binary path — outside comments). A package-wide audit test SHALL assert that no target other than LogosUsage contains a Security import in compiled code.

#### Scenario: Package-wide import scope scan

- **WHEN** the red-line audit tests run over the package sources
- **THEN** a Security import appears only under the LogosUsage target's sources
- **AND** LogoSwitch, LogosAccounts, and Logos app sources contain none of the forbidden credential-access tokens

#### Scenario: LogoSwitch red line is unchanged

- **WHEN** the pre-existing LogoSwitch red-line audit test runs
- **THEN** it passes with its original forbidden-token list, unmodified by the merge

---
### Requirement: Keychain writes are structurally forbidden package-wide

No source file in any target of the package — including LogosUsage — SHALL contain SecItemAdd, SecItemUpdate, or SecItemDelete tokens in compiled code. An audit test SHALL enforce this over the entire package source tree, making the read-only property structural rather than conventional.

#### Scenario: Write-token scan over the whole package

- **WHEN** the write-token audit test runs
- **THEN** no SecItemAdd, SecItemUpdate, or SecItemDelete token is found in any target's compiled code, comments excluded
