## Why

MultiStats (the multi-account Claude Code usage viewer) has turned out to be Logos-scoped in practice: it discovers accounts only through the Logos config-dir convention (per-account CLAUDE_CONFIG_DIR under the Logos accounts root), and its audience is Logos users. Keeping it in a separate repo duplicates the account-convention code in two places, splits issue tracking, and blocks the product direction the maintainer has chosen: Logos consumes a single shared account registry and shows per-account usage in its own window, while MultiStats survives only as a thin standalone viewer executable.

## What Changes

- Merge the MultiStats package into the logos repo via a history-preserving subtree merge.
- New target LogosAccounts: the credential-free account registry — account model, config-dir convention (single source of truth; today duplicated across both repos), filesystem discovery, create/rename/remove, and persistence in a shared JSON index file at the Logos accounts root, with a one-time migration from the existing UserDefaults store. Foundation-only.
- New target LogosUsage: read-only Keychain credential reading, usage API client, and per-account usage view model (imported from MultiStatsCore). This becomes the ONLY target permitted to import Security.
- Red-line audit coverage extended: LogoSwitch keeps its existing Foundation-only red line unchanged; LogosAccounts and the Logos app target gain the same source-scan guarantee; LogosUsage is fenced as the single audited Keychain read path (read-only — no SecItemAdd/Update/Delete, no token refresh).
- **BREAKING** (library surface): LogoSwitch's AccountManager slims down to launcher state (active selection, live-401 observation, spawn glue) and delegates registry operations to LogosAccounts; the Account model and registry API move targets.
- Logos main app gains a usage window that renders per-account plan-usage bars for all registered accounts.
- The MultiStats standalone executable is retained as a thin product of the merged package.
- External repo hygiene: open MultiStats issues are transferred to the logos repo, then the MultiStats repo is archived with a pointer README.

## Capabilities

### New Capabilities

- `account-registry`: shared, credential-free account registry — discovery, creation, rename, removal, and file-based persistence of the account list, consumable by both the Logos app and the standalone viewer executable
- `usage-display`: read-only retrieval and display of per-account Claude Code usage — Keychain credential read, usage endpoint client, expiry handling, and the usage UI surfaces (Logos window + standalone executable)

### Modified Capabilities

- `account-credential-isolation`: isolation requirements extend to the merged targets — Security imports are confined to the LogosUsage target, Keychain access is strictly read-only, and the registry/launcher/app targets remain structurally incapable of credential access

## Impact

- Affected specs: `account-registry` (new), `usage-display` (new), `account-credential-isolation` (modified)
- Affected code:
  - New: Sources/LogosAccounts/ (registry target), Sources/LogosUsage/ (Keychain reader + usage client + view model), Sources/MultiStats/ (thin standalone executable + its SwiftUI views), Tests/LogosAccountsTests/, Tests/LogosUsageTests/, usage window views under Sources/Logos/Views/
  - Modified: Package.swift, Sources/LogoSwitch/AccountManager.swift, Sources/LogoSwitch/AccountStore.swift, Sources/LogoSwitch/Account.swift, Tests/LogoSwitchTests/RedLineAuditTests.swift
  - Removed: none in this repo (the external MultiStats repository is archived after issue transfer; that is an external action, not a code removal here)
- Dependencies: no new third-party dependencies. LogoSwitch gains one internal dependency on LogosAccounts (both remain Foundation-only). The Logos app target gains internal dependencies on LogosAccounts and LogosUsage.
