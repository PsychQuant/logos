## Why

Logos's multi-account feature swaps a single shared macOS Keychain entry (`service="Claude Code-credentials"`, `account=$USER`) between accounts via `AccountManager.setActive` → `SystemKeychainBridge.write`. On macOS 26, an unsandboxed Developer-ID app writing that cross-identity entry can trigger the system-modal "找不到鑰匙圈來儲存「<user>」" reset dialog, whose "重置為預設值" button cascade-corrupts the login keychain (Safari/Mail/Wi-Fi/VPN). Issue #3 only removed the launch-time trigger; the user-gesture swap path is structurally unchanged (issue #12).

A grounding finding makes a clean fix available: the claude CLI derives its Keychain service from `CLAUDE_CONFIG_DIR` (`service = "Claude Code-credentials-<sha256(configDir)[0:8]>"` when set; the bare name otherwise). `ClaudeProcessConfig` already overrides `HOME` per account, but `HOME` alone leaves claude on the bare shared entry — so every account currently reads the same entry, which is the only reason Logos performs the swap-write at all.

## What Changes

- `ClaudeProcessConfig` emits `CLAUDE_CONFIG_DIR` per account so each account's claude reads/writes its OWN per-config-dir Keychain entry. Logos stops writing the shared entry.
- **BREAKING (internal): `AccountManager.setActive` / `remove` no longer swap the system Keychain entry.** Switching becomes pure local active-state plus the next spawn's `CLAUDE_CONFIG_DIR`.
- `SystemKeychainBridge`'s production write/delete path is retired (the dialog-triggering calls). The protocol is slimmed to read-only or removed if no consumer remains.
- Account onboarding/(re)auth happens via `claude login` run under the account's `CLAUDE_CONFIG_DIR` (claude writes its own entry); Logos never writes claude credentials.
- Migration: the bare `Claude Code-credentials` entry is never deleted or overwritten (cascade risk + keeps plain-terminal `claude` working). Existing accounts are marked needs-reauth and re-login once under their config dir.
- An empirical verification gate (terminal-only) confirms `CLAUDE_CONFIG_DIR` yields distinct per-dir Keychain entries before the behavior change lands.

## Non-Goals

- Adopting `che-keychain` for claude credentials (rejected: its writes are interactive/user-typed with no caller-supplied value, and claude creds are browser-OAuth tokens — wrong primitive; the architecture-level rationale lives in design.md).
- Sandboxing the app or adding a provisioning-profile `keychain-access-groups` entitlement.
- Any change to Logos's own `AccountCredentialStore` service (`app.getlogos.logos.credentials`) as a credential-delivery mechanism beyond what migration needs.

## Capabilities

### New Capabilities

- `account-credential-isolation`: each Logos account's claude credentials are isolated in claude's own per-`CLAUDE_CONFIG_DIR` Keychain entry; account switching never writes the shared system Keychain entry.

### Modified Capabilities

(none)

## Impact

- Affected specs: new capability `account-credential-isolation`
- Affected code:
  - Modified:
    - Sources/Logos/Models/ClaudeProcessConfig.swift
    - Sources/Logos/Models/AccountManager.swift
    - Sources/Logos/Services/SystemKeychainBridge.swift
    - Sources/Logos/Models/Account.swift
    - CHANGELOG.md
  - New:
    - Tests/LogosTests/AccountCredentialIsolationTests.swift
  - Removed:
    - (none — write/delete are removed from the production conformer in-place, not as file deletions)
