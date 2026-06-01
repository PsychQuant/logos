## ADDED Requirements

### Requirement: Critical lifecycle events are observable via the unified log

The app SHALL emit an `os.Logger` `.notice` record for each critical lifecycle moment under the subsystem `app.getlogos.logos`, so the event is retained in the unified-log store and queryable after the fact without a GUI or TCC grant. The covered moments SHALL include: application launch finished, workspace load success, claude process spawned, claude process exited, session phase change and restart, account switch and config-dir materialize, settings change, and OAuth login URL detected.

Lifecycle events MUST use `.notice` (or higher), never `.info` or `.debug`, because only `.notice` and above persist to the store and remain visible to `log show` after the run.

#### Scenario: Spawn and exit are queryable after the fact

- **WHEN** the app launches, hosts a claude process, and that process later exits
- **THEN** a query of `log show --predicate 'subsystem == "app.getlogos.logos"'` returns a `.notice` record for the spawn and a `.notice` record for the exit, each carrying its category

#### Scenario: Workspace load success is logged, not only failure

- **WHEN** the app successfully loads a workspace tree
- **THEN** a `.notice` record for workspace load success is emitted (in addition to the pre-existing failure-path `.error` record)

### Requirement: Lifecycle log payloads follow the redaction posture

Lifecycle records SHALL mark only non-sensitive scalar values as public — exit codes, booleans, enum case names, counts, and generation numbers. Filesystem paths, account identifiers, environment values, error descriptions, tokens, and credentials SHALL remain default-redacted (rendered as `<private>` in the store) and MUST NOT be marked public.

#### Scenario: Sensitive values are redacted while scalars stay readable

- **WHEN** an account switch and a claude exit are logged
- **THEN** the account identifier appears as `<private>` while the exit code appears in clear text

##### Example: Public vs private fields

| Field | Posture | Rendered in store |
| ----- | ------- | ----------------- |
| exit code (Int) | public | `0` |
| dangerous-mode flag (Bool) | public | `true` |
| account id (String) | private | `<private>` |
| executable path / env | not logged | (absent) |

### Requirement: A headless smoke test asserts the critical lifecycle flow

The project SHALL provide a headless smoke test that launches the real bundled application against a temporary workspace and asserts the critical-flow lifecycle sequence (launch, workspace load, claude spawn, process exit, restart) by reading the unified-log trail. The smoke test SHALL NOT require valid claude credentials: it asserts that the spawn and exit lifecycle records appear, and tolerates claude's own authentication failure. The smoke test SHALL be runnable without launching from the default unit-test run.

#### Scenario: Smoke passes without credentials

- **WHEN** the smoke test launches the bundled app with no authenticated account
- **THEN** the test observes the spawn and exit `.notice` records within its timeout and passes, regardless of whether claude authenticated

#### Scenario: Missing lifecycle event fails the smoke test

- **WHEN** an expected lifecycle `.notice` (for example, the spawn record) is absent within the timeout
- **THEN** the smoke test fails and reports the lifecycle records it actually observed

### Requirement: A UI end-to-end test asserts pixel-level critical behavior

The project SHALL provide a UI end-to-end test, hosted in a window-server context, that launches the application and asserts behavior the log trail cannot prove. The first such test SHALL open the Settings window and assert that the window appears without the application process terminating — the regression contract for the Settings-open crash (PsychQuant/logos#20).

#### Scenario: Opening Settings does not crash and shows a window

- **WHEN** the UI test launches the app and opens Settings
- **THEN** the Settings window exists within a short timeout and the application process is still running
