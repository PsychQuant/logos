## ADDED Requirements

### Requirement: Security framework usage is confined to the audited usage target

Within the merged package, the Security framework SHALL be importable only by the LogosUsage target. The sources of LogoSwitch, LogosAccounts, and the Logos app target SHALL pass the red-line forbidden-token scan (Security import, SecItem tokens, find-generic-password, add-generic-password, and the security(1) binary path — outside comments). A package-wide audit test SHALL assert that no target other than LogosUsage contains a Security import in compiled code.

#### Scenario: Package-wide import scope scan

- **WHEN** the red-line audit tests run over the package sources
- **THEN** a Security import appears only under the LogosUsage target's sources
- **AND** LogoSwitch, LogosAccounts, and Logos app sources contain none of the forbidden credential-access tokens

#### Scenario: LogoSwitch red line is unchanged

- **WHEN** the pre-existing LogoSwitch red-line audit test runs
- **THEN** it passes with its original forbidden-token list, unmodified by the merge

### Requirement: Keychain writes are structurally forbidden package-wide

No source file in any target of the package — including LogosUsage — SHALL contain SecItemAdd, SecItemUpdate, or SecItemDelete tokens in compiled code. An audit test SHALL enforce this over the entire package source tree, making the read-only property structural rather than conventional.

#### Scenario: Write-token scan over the whole package

- **WHEN** the write-token audit test runs
- **THEN** no SecItemAdd, SecItemUpdate, or SecItemDelete token is found in any target's compiled code, comments excluded

## MODIFIED Requirements

### Requirement: The shared bare Keychain entry is never mutated

Logos SHALL NOT delete or overwrite the bare `Claude Code-credentials` entry under any account operation, usage refresh, or migration step, and this mutation ban SHALL extend to every target in the merged package (including the read-only usage target). The bare entry belongs to the user's plain-terminal `claude login` and mutating it risks a login-keychain cascade. Within the Logos app, any read of the bare entry SHALL occur only during an explicit, user-initiated migration check; the Logos usage window SHALL NOT read the bare entry, because it renders registry accounts only and the default account is not a registry entry. Outside the Logos app, read-only access to the bare entry SHALL be limited to the standalone viewer executable reading it through the read-only credentials reader during a user-initiated usage refresh.

#### Scenario: Plain-terminal claude is unaffected

- **WHEN** any Logos account operation (add, switch, remove, migrate) completes
- **THEN** the bare `Claude Code-credentials` entry is byte-identical to its pre-operation value
- **AND** a `claude` invocation run outside Logos continues to authenticate

#### Scenario: Usage refresh leaves the bare entry untouched

- **WHEN** a usage refresh completes in the Logos usage window or the standalone viewer
- **THEN** the bare `Claude Code-credentials` entry is byte-identical to its pre-refresh value

#### Scenario: The Logos usage window does not read the bare entry

- **WHEN** the Logos usage window refreshes
- **THEN** every Keychain read uses a hash-suffixed per-directory service name and none uses the bare service name
