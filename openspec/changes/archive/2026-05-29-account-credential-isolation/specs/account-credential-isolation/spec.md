## ADDED Requirements

### Requirement: Account switching performs no system Keychain write

Switching the active account (`AccountManager.setActive`) and removing an account (`AccountManager.remove`) SHALL NOT write to or delete from the shared system Keychain entry (`service="Claude Code-credentials"`). Switching SHALL change only Logos-local active state and the per-spawn `CLAUDE_CONFIG_DIR`. This removes the cross-identity `SecItem` write that can trigger the macOS reset dialog.

#### Scenario: Switching active account does not write the Keychain

- **WHEN** the user selects a different account in the account switcher
- **THEN** no `SecItemAdd`, `SecItemUpdate`, or `SecItemDelete` is performed against the shared `Claude Code-credentials` entry
- **AND** no macOS Keychain consent or reset dialog is surfaced by the switch

#### Scenario: Removing an account does not write the Keychain

- **WHEN** the user removes an account (including the active one)
- **THEN** the shared system Keychain entry is not written or deleted by Logos

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

### Requirement: The shared bare Keychain entry is never mutated

Logos SHALL NOT delete or overwrite the bare `Claude Code-credentials` entry under any account operation or migration step. The bare entry belongs to the user's plain-terminal `claude login` and mutating it risks a login-keychain cascade. Any read of the bare entry SHALL occur only during an explicit, user-initiated migration check; Logos SHALL perform no other access to it.

#### Scenario: Plain-terminal claude is unaffected

- **WHEN** any Logos account operation (add, switch, remove, migrate) completes
- **THEN** the bare `Claude Code-credentials` entry is byte-identical to its pre-operation value
- **AND** a `claude` invocation run outside Logos continues to authenticate

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

### Requirement: Existing accounts migrate non-destructively

On upgrade to the isolated-credential model, existing accounts SHALL be migrated without Logos writing any Keychain credential. Each existing account SHALL be marked needs-reauth unless its per-directory item already exists, and the previously-active account's bare entry SHALL be left in place so it keeps working until the user re-authenticates.

#### Scenario: Upgrade marks accounts for re-auth without writing credentials

- **WHEN** the user first launches the build that introduces credential isolation
- **THEN** each account lacking a per-directory credential item is marked needs-reauth
- **AND** no Keychain credential is written by Logos during migration
- **AND** the bare `Claude Code-credentials` entry is left untouched
