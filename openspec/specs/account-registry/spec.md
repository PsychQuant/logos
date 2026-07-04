# account-registry Specification

## Purpose

TBD - created by archiving change 'merge-multistats-into-logos'. Update Purpose after archive.

## Requirements

### Requirement: Account list persists in a shared file-based index

The account registry SHALL persist the account list in a JSON index file at the Logos accounts root (accounts/index.json under the Logos data directory in the user home), NOT in any per-app store. The index SHALL contain a `version` field (integer, initially 1) and an `accounts` array where each entry carries `id` (string), `label` (string), and `createdAt` (ISO-8601 date). Writes SHALL be atomic (write to a temporary file, then rename), so a crash mid-write never leaves a truncated index.

#### Scenario: A mutation in one executable is visible to the other

- **WHEN** the user creates or renames an account in the Logos app and then launches the standalone viewer
- **THEN** the standalone viewer lists the same accounts with the same labels, read from the shared index file

##### Example: index file shape

- **GIVEN** two accounts: work (created 2026-07-01) and personal (created 2026-07-02)
- **WHEN** the registry saves
- **THEN** the index file contains version 1 and an accounts array of two objects, each with id, label, and createdAt fields

#### Scenario: Writes are atomic

- **WHEN** the registry saves the account list
- **THEN** the index file is replaced via temporary-file-plus-rename
- **AND** a reader never observes a partially written index

---
### Requirement: Legacy per-app account data migrates non-destructively

On first load, when the shared index file is absent and the legacy UserDefaults key `logos.accounts` holds decodable account data, the registry SHALL decode it and write the shared index file from it. The legacy UserDefaults data SHALL NOT be deleted or overwritten by migration; after a successful migration the registry SHALL read and write only the index file.

#### Scenario: Existing accounts survive the upgrade

- **WHEN** a user with accounts stored in legacy UserDefaults launches the first build with the shared registry
- **THEN** the shared index file is created containing exactly those accounts (ids, labels, createdAt preserved)
- **AND** the legacy UserDefaults value remains in place unmodified

#### Scenario: Undecodable legacy data fails safe

- **WHEN** the index file is absent and the legacy UserDefaults data cannot be decoded
- **THEN** the registry starts empty and records a log notice
- **AND** the legacy UserDefaults data is left untouched

---
### Requirement: A corrupt index file is never silently destroyed

When the index file exists but cannot be parsed, the registry SHALL load as empty and record a log notice, and SHALL NOT overwrite the corrupt file until the first explicit user-initiated mutation (create, rename, or remove).

#### Scenario: Corrupt index is preserved for inspection

- **WHEN** the registry loads a corrupt index file
- **THEN** the account list presents as empty and a log notice records the parse failure
- **AND** the corrupt file remains byte-identical on disk until the user performs a registry mutation

---
### Requirement: The registry target is structurally credential-free

The LogosAccounts target SHALL link only Foundation (no Security framework), and its sources SHALL be covered by the red-line audit scan that forbids credential-access tokens (Security import, SecItem calls, and security(1) shell-outs) outside comments.

#### Scenario: Audit scan covers the registry target

- **WHEN** the red-line audit tests run
- **THEN** every source file of the LogosAccounts target passes the forbidden-token scan

---
### Requirement: The config-dir convention has a single source of truth

The derivation of an account's config directory (the accounts root joined with the account id and the claude config directory name) SHALL exist only in the LogosAccounts target. Account discovery SHALL scan the default claude config directory in the user home plus the Logos accounts root, and SHALL exclude shell directories that lack a top-level claude config JSON (never-logged-in leftovers).

#### Scenario: Shell directories are filtered out of discovery

- **WHEN** discovery scans an accounts root containing initialized accounts and empty shell directories
- **THEN** only directories with a locatable top-level claude config JSON are returned as accounts

#### Scenario: Default account is discovered alongside convention accounts

- **WHEN** the default claude config directory exists with its top-level config JSON
- **THEN** discovery returns it as the default account, followed by the convention accounts sorted by directory name

---
### Requirement: Registry mutations validate labels

Account creation and rename SHALL validate labels: a trimmed label MUST be non-empty, MUST NOT exceed 30 characters, and MUST NOT duplicate another account's label. Renaming an account to its own current label SHALL succeed. A rename SHALL preserve the account id and createdAt, so it never moves the config directory or invalidates a login.

#### Scenario: Label validation outcomes

- **WHEN** the user submits a label for create or rename
- **THEN** the registry accepts or rejects it per the validation rules

##### Example: validation cases

| Input | Existing labels | Operation | Expected |
| ----- | --------------- | --------- | -------- |
| "" | (any) | create | rejected: empty label |
| 31 characters | (any) | create | rejected: label too long |
| "work" | work, personal | create | rejected: duplicate label |
| "work" | work (same account) | rename | accepted (own label) |
| "Work 2" | work, personal | rename | accepted, id and createdAt preserved |

---
### Requirement: Active selection stays out of the shared registry

The shared index file SHALL contain only the account list. The active-account selection is launcher UI state and SHALL remain in the Logos app's local store; the standalone viewer SHALL NOT read or write any active-selection state.

#### Scenario: Selection changes do not touch the index file

- **WHEN** the user switches the active account in Logos
- **THEN** the shared index file is not written
