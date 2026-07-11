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

Account creation and rename SHALL validate labels against a two-dimensional size bound. A label SHALL first be trimmed of leading and trailing whitespace and newlines (the `.whitespacesAndNewlines` set — the same set on every path, so a newline-bearing label decoded from disk trims identically to one typed into the UI). A trimmed label MUST be non-empty, MUST NOT exceed 30 extended grapheme clusters, MUST NOT exceed 256 UTF-8 bytes, and MUST NOT duplicate another account's label. The grapheme cap and the byte cap are independent: a label within 30 grapheme clusters that still carries more than 256 UTF-8 bytes (a combining-mark "zalgo" cluster, or a long ZWJ emoji sequence) MUST be rejected, because grapheme count alone does not bound the persisted byte size and an unbounded label can push the whole index past its file-size cap and be dropped on load.

On the mutation path (create, rename) an over-budget label SHALL be rejected with a label-too-long error. On the load-time repair path (index normalization) an over-budget label SHALL instead be silently clamped rather than rejected: the clamp SHALL truncate on a grapheme-cluster boundary — accumulating whole clusters until the next would exceed 256 UTF-8 bytes — so a repaired label is never left with a split grapheme cluster or mojibake. When the load-time repair uniquifies two isolated accounts whose labels collide at or near the byte cap, it SHALL append the disambiguating suffix so the suffix itself survives the byte cap — clamping the base label to leave room for the suffix rather than letting the byte clamp truncate the suffix away — so the two accounts retain DISTINCT persisted labels rather than silently remaining duplicates. Renaming an account to its own current label SHALL succeed. A rename SHALL preserve the account id and createdAt, so it never moves the config directory or invalidates a login.

#### Scenario: Label validation outcomes

- **WHEN** the user submits a label for create or rename
- **THEN** the registry accepts or rejects it per the validation rules

##### Example: validation cases

| Input | Existing labels | Operation | Expected |
| ----- | --------------- | --------- | -------- |
| "" | (any) | create | rejected: empty label |
| 31 grapheme clusters | (any) | create | rejected: label too long |
| 1 base char + 4000 combining marks (1 grapheme cluster, ~8 KB UTF-8) | (any) | create | rejected: label too long (over the 256-byte cap despite being 1 grapheme) |
| "work" | work, personal | create | rejected: duplicate label |
| "work" | work (same account) | rename | accepted (own label) |
| "Work 2" | work, personal | rename | accepted, id and createdAt preserved |

#### Scenario: Load-time repair clamps an over-budget label on a grapheme boundary

- **WHEN** the registry loads and normalizes an index whose label is within 30 grapheme clusters but exceeds 256 UTF-8 bytes
- **THEN** normalization clamps the label to at most 256 UTF-8 bytes by dropping whole trailing grapheme clusters
- **AND** the persisted label round-trips as valid `Character`s (no cluster is split mid-scalar)
- **AND** an index whose labels are already within both caps is not rewritten by normalization (the net-change convergence from the prior label-repair pass is preserved, so a clean index is never re-saved on load)

##### Example: byte-cap clamp on a grapheme boundary

- **GIVEN** a persisted label of 30 ZWJ family-emoji clusters (each 25 UTF-8 bytes = 750 bytes total, but only 30 grapheme clusters, so it passes the grapheme cap)
- **WHEN** the registry loads and normalizes
- **THEN** the label is clamped to the largest whole-grapheme prefix whose utf8.count ≤ 256 — 10 family-emoji clusters (250 bytes); the 11th would reach 275 bytes and is dropped whole
- **AND** no family-emoji cluster is left partially truncated (no dangling ZWJ or lone scalar)

#### Scenario: Load-time uniquify keeps the disambiguating suffix under the byte cap

- **WHEN** the registry loads and normalizes an index in which two isolated accounts share a label at or near the 256-UTF-8-byte cap (e.g. a single grapheme cluster of exactly 256 bytes)
- **THEN** normalization keeps the earlier occurrence's label and appends a `" (recovered)"` disambiguator to the later one, clamping the base first so the suffix is never truncated by the byte cap
- **AND** the two accounts end with DISTINCT persisted labels whose disambiguating suffix is visible (the duplicate is not silently preserved by a stripped suffix)
- **AND** the repaired index converges — a subsequent load does not rewrite it, because the byte clamp is idempotent and the realized (post-clamp) labels are compared for the net change

##### Example: suffix survives at the byte cap

- **GIVEN** two isolated accounts persisted with the identical label of a single grapheme cluster of exactly 256 UTF-8 bytes
- **WHEN** the registry loads and normalizes
- **THEN** the first keeps the 256-byte label and the second is stored as a distinct label carrying a visible `(recovered)` suffix, each within the 256-byte cap
- **AND** reloading the repaired index is a no-op (no re-save)

---
### Requirement: Active selection stays out of the shared registry

The shared index file SHALL contain only the account list. The active-account selection is launcher UI state and SHALL remain in the Logos app's local store; the standalone viewer SHALL NOT read or write any active-selection state.

#### Scenario: Selection changes do not touch the index file

- **WHEN** the user switches the active account in Logos
- **THEN** the shared index file is not written
