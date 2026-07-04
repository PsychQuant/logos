## ADDED Requirements

### Requirement: Keychain credential access is strictly read-only

The usage feature SHALL read stored claude OAuth credentials via SecItemCopyMatching only. It SHALL NOT add, update, or delete any Keychain item, SHALL NOT perform token refresh (an expired access token surfaces as a display state, never an automatic refresh), and SHALL NOT log token material.

#### Scenario: Expired token becomes a display state

- **WHEN** an account's stored access token is past its expiry at refresh time
- **THEN** that account renders in an expired state directing the user to re-authenticate via claude
- **AND** no refresh-token exchange is attempted

#### Scenario: Unknown expiry defers to the endpoint

- **WHEN** stored credentials carry no expiry timestamp
- **THEN** the usage request is attempted and an unauthorized response surfaces as the error state (the account is not pre-emptively hidden)

### Requirement: Keychain service names follow claude's own derivation

Credential lookup SHALL use claude's service-name convention: the default account (default claude config directory) uses the bare service name, and a per-directory account uses the bare name suffixed with the first 8 hex characters of the SHA-256 of the config directory's absolute path.

#### Scenario: Service name per account kind

- **WHEN** credentials are looked up for a default account and for a convention account
- **THEN** the default lookup uses the bare service name and the convention lookup uses the hash-suffixed service name

##### Example: service-name derivation

| Account | Config dir | Service name |
| ------- | ---------- | ------------ |
| default | ~/.claude | Claude Code-credentials |
| work | ~/.logos/accounts/work/.claude | Claude Code-credentials-<first 8 hex of sha256(path)> |

### Requirement: Per-account usage retrieval is isolated

Each account's usage retrieval SHALL be independent: a failure for one account (missing credentials, denied Keychain read, endpoint error) SHALL NOT block, delay indefinitely, or clear the results of other accounts.

#### Scenario: One failing account leaves the rest intact

- **WHEN** the usage endpoint returns an error for one account while others succeed
- **THEN** the failing account shows a per-account error state and every other account shows its loaded usage

### Requirement: Missing or denied credentials surface as a quiet display state

When a Keychain read returns nothing (item absent or access denied), the account SHALL render in a no-credentials state. The feature SHALL NOT retry the read in a loop and SHALL NOT trigger repeated authorization prompts for the same account within one refresh pass.

#### Scenario: Denied read does not prompt-storm

- **WHEN** the user declines the Keychain authorization prompt for one account
- **THEN** that account shows the no-credentials state and no further read is attempted until the user explicitly refreshes

### Requirement: First authorization pass serializes Keychain reads

On the first refresh after launch, credential reads across accounts SHALL be serialized (one at a time) so that first-run macOS Keychain authorization dialogs appear one by one instead of stacking.

#### Scenario: First refresh with multiple unauthorized accounts

- **WHEN** the first refresh runs against multiple accounts whose Keychain items have not yet authorized this app
- **THEN** at most one Keychain authorization dialog is pending at any moment

### Requirement: The Logos usage window renders the registry

The usage window inside the Logos app SHALL list exactly the accounts in the shared registry, showing each account's label, identity when known (from its config JSON), plan-usage window consumption, and credential state. It SHALL run no filesystem discovery of its own. Refresh SHALL occur on window open and on explicit user action. The window is display-only: it SHALL offer no account switching, no login, and no registry mutation.

#### Scenario: Window matches the registry

- **WHEN** the usage window opens
- **THEN** the listed accounts equal the shared registry's account list (same ids, same labels, same order policy as the accounts settings)

#### Scenario: Display-only surface

- **WHEN** the user interacts with the usage window
- **THEN** no action available in the window mutates the registry, the Keychain, or the active-account selection

### Requirement: The standalone viewer keeps discovery-based parity

The standalone viewer executable SHALL discover accounts via LogosAccounts discovery (default account plus convention accounts), render the same per-account states as the Logos usage window, and apply registry labels when the shared index file is present.

#### Scenario: Standalone viewer without Logos data

- **WHEN** the standalone viewer runs on a machine with only a default claude account and no accounts root
- **THEN** it lists the single default account with its usage

#### Scenario: Standalone viewer with registry labels

- **WHEN** the shared index file exists and contains a label for a discovered convention account
- **THEN** the standalone viewer shows that label for the account
