## MODIFIED Requirements

### Requirement: The shared bare Keychain entry is never mutated

Logos SHALL NOT delete or overwrite the bare `Claude Code-credentials` entry under any account operation, usage refresh, or migration step, and this mutation ban SHALL extend to every target in the merged package (including the read-only usage target). The bare entry belongs to the user's plain-terminal `claude login` and mutating it risks a login-keychain cascade. Within the Logos app, any read of the bare entry SHALL be limited to two read-only cases: (a) an explicit, user-initiated migration check, and (b) the Logos usage window resolving plan usage for the system-default account, whose claude credential is the bare entry because it reuses `~/.claude`. The Logos usage window MAY read the bare entry read-only when resolving the system-default account's row; it SHALL NOT read the bare entry for isolated accounts. These reads are read-only and SHALL NOT relax the mutation ban above. Outside the Logos app, read-only access to the bare entry SHALL be limited to the standalone viewer executable reading it through the read-only credentials reader during a user-initiated usage refresh.

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
