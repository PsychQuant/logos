## Context

Logos supports multiple Claude accounts. Today `AccountManager.setActive(_:)` makes the chosen account "active" by reading the shared macOS Keychain entry (`service="Claude Code-credentials"`, `account=$USER`), backing the previous value up to Logos's own `AccountCredentialStore` (`service="app.getlogos.logos.credentials"`), and writing the target account's stored blob into the shared entry via `SystemKeychainBridge.write` (which performs `SecItemUpdate` → `SecItemAdd`). The spawned `claude` then reads that shared entry at runtime.

On macOS 26, an unsandboxed Developer-ID app performing that cross-identity write can trigger a system-modal "找不到鑰匙圈來儲存「<user>」" dialog whose "重置為預設值" button can reset/recreate `login.keychain`, cascade-corrupting Safari/Mail/Wi-Fi/VPN entries. Issue #3 removed the launch-time trigger but left the user-gesture swap path intact (issue #12).

Grounding finding (claude v2.1.156, confirmed by source-level inspection of the installed Bun-compiled binary on 2026-05-29): claude builds its credential service name as `` `Claude Code${OAUTH_FILE_SUFFIX}-credentials${suffix}` ``, where `OAUTH_FILE_SUFFIX` is `""` in production and `suffix` is `""` when no secure-storage config directory is set, or `` `-${sha256(K).hex.substring(0,8)}` `` when one is set. `K` is the secure-storage config directory, NFC-normalized, resolved by a dedicated resolver: it reads `CLAUDE_SECURESTORAGE_CONFIG_DIR` when that variable is DEFINED (a defined-but-empty value collapses to `homedir()/.claude`, i.e. the bare service name), and falls back to `CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")` only when `CLAUDE_SECURESTORAGE_CONFIG_DIR` is UNDEFINED. So setting `CLAUDE_CONFIG_DIR` alone (with `CLAUDE_SECURESTORAGE_CONFIG_DIR` unset) yields the hashed per-account name, but an inherited empty `CLAUDE_SECURESTORAGE_CONFIG_DIR` would silently force the bare name. claude also reads a file-based credential fallback at `<config-dir>/.credentials.json` from the same secure-storage directory. `ClaudeProcessConfig` already sets `env["HOME"]` per account, but `HOME` alone does NOT change the service name — so all accounts currently read the same bare entry, which is the sole reason the swap-write exists.

## Goals / Non-Goals

**Goals:**

- Eliminate the shared-entry write entirely so the macOS reset dialog can no longer be triggered by Logos.
- Give each account its own claude credential storage (claude's own per-config-dir Keychain item).
- Preserve the user's plain-terminal `claude login` (the bare entry) untouched.
- Migrate existing accounts non-destructively (no deletion/overwrite of the bare entry).

**Non-Goals:**

- Delegating claude credentials through `che-keychain`. Rejected: `che-keychain`'s writes are interactive (the user types the secret) with no caller-supplied value and it has no read; claude credentials are browser-OAuth tokens nobody types, so it is the wrong primitive. (`che-keychain` remains appropriate for user-typed secrets elsewhere.)
- Adding a `keychain-access-groups` entitlement or sandboxing the app.
- Redesigning `AccountCredentialStore` as a credential-delivery mechanism (it may retain non-credential per-account metadata only).
- A full credential-import-from-bare-entry automation (migration is re-login-based, see Migration Plan).

## Decisions

### D1: Per-account `CLAUDE_CONFIG_DIR` isolation (chosen)

Each account gets a stable config dir (e.g. `<account.homeDirectoryPath>/.claude`); `ClaudeProcessConfig` emits `env["CLAUDE_CONFIG_DIR"] = <that dir>`. claude then reads/writes its OWN hashed Keychain item per account. Switching accounts is just changing which `CLAUDE_CONFIG_DIR` the next spawn uses — no Keychain mutation by Logos.

Alternatives considered:
- **`HOME`-only override (status quo)**: ineffective — claude stays on the bare entry, forcing the swap-write. Rejected.
- **Delegate the write to `che-keychain`**: relocates the dangerous write into a signed binary, but (a) requires extending `che-keychain` with a non-interactive value-passing write + read it does not have, (b) rests on an unverified assumption that a signed binary's write avoids the macOS-26 dialog (the dialog may be about the shared item, not the caller), and (c) `che-keychain`'s user-types model does not fit OAuth tokens. Higher risk, cross-repo, and does not remove the write. Rejected as primary.
- **XPC/Unix-socket credential bridge**: highest complexity (separate signed helper, lifecycle, protocol); solves a problem `CLAUDE_CONFIG_DIR` removes for free. Rejected.

### D2: Retire `SystemKeychainBridge`'s write/delete path

Once Logos no longer swaps, `SystemKeychainBridge.write`/`delete` (the dialog-triggering calls) are removed from the production conformer. The protocol is slimmed to read-only (kept only if migration needs the capture-read) or removed entirely. Interface-depth note: the bridge existed to serve the swap; removing the swap is what lets the abstraction shrink — its deletion test (what breaks if removed?) now answers "only migration-read + tests", confirming the simplification.

### D3: Onboarding/(re)auth via `claude login` under the account's config dir

Each account authenticates by running `claude login` with its `CLAUDE_CONFIG_DIR` set (inside Logos's terminal). claude writes its own per-dir entry; Logos never writes claude credentials. This keeps claude as the sole owner/writer of every credential item.

### D4: Non-destructive migration

The bare `Claude Code-credentials` entry is never deleted or overwritten by this change (cascade risk + it is the plain-terminal user's working credential). Existing Logos accounts are marked needs-reauth and the user re-logs-in once per account under its config dir.

### D5: Empirical verification gate before the behavior change

Because the claude credential scheme is reverse-engineered and version-pinned, the premise is confirmed before any code lands. Status: SATISFIED on 2026-05-29 by source-level inspection of the installed v2.1.156 binary (the user's exact version), which is stronger than a behavioral repro — it yields the exact algorithm (`sha256` of the NFC-normalized config-dir string, first 8 hex chars), the env precedence (`CLAUDE_SECURESTORAGE_CONFIG_DIR` over `CLAUDE_CONFIG_DIR`, empty-string trap), and the `.credentials.json` file fallback. A behavioral terminal repro (two `CLAUDE_CONFIG_DIR=<dir> claude login` runs yielding two distinct `Claude Code-credentials-<hash>` items) remains available as optional confirmation but is not required. This gate MUST be re-checked when claude is upgraded, since the scheme is not a public contract.

## Implementation Contract

**Behavior (observable):**
- Switching the active account in `AccountSwitcherSheet` performs NO macOS Keychain write and can never surface the "找不到鑰匙圈" reset dialog.
- A spawned `claude` for account A is authenticated as A and for account B as B, with no shared mutable state between them.
- The bare `Claude Code-credentials` entry is byte-identical before and after any Logos account operation; a plain-terminal `claude` continues to work.
- An account whose per-config-dir credential does not yet exist is shown in a needs-reauth state (surfaced in the switcher), not silently broken.

**Interface / data shape:**
- `ClaudeProcessConfig` emits `environment["CLAUDE_CONFIG_DIR"] = account.configDirPath` for an account-scoped spawn AND `environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = account.configDirPath` (the same path). Setting both is belt-and-suspenders: `CLAUDE_SECURESTORAGE_CONFIG_DIR` is the variable that actually keys the Keychain service name, and an empty value inherited from the parent environment would silently collapse to the bare name. The emitter MUST NOT pass `CLAUDE_SECURESTORAGE_CONFIG_DIR` as an empty string (overwrite or remove any inherited empty value). The `HOME` override may remain or be dropped; the two config-dir variables are load-bearing.
- `Account` gains a `configDirPath` (the per-account claude config directory; e.g. derived from `homeDirectoryPath`).
- `AccountManager.setActive(_:)` and `remove(accountId:)` no longer call `systemBridge.write` / `systemBridge.delete`; switching updates only local active-state and persisted account list.
- `SystemKeychainBridge`: `write` and `delete` are removed from the production conformer `RealSystemKeychainBridge`. `read`/`exists` are retained only if migration's capture-read needs them; otherwise the protocol is removed. The in-memory test double is updated to match the slimmed protocol.

**Failure modes:**
- Missing per-account credential → needs-reauth state (surfaced), prompting `claude login` under that account's config dir. Never a silent blank session. needs-reauth is computed from PROMPTLESS signals only (Logos never reads the system Keychain for this — a cross-identity read can surface an access prompt and re-couples Logos to the keychain). "Credential present" means EITHER Logos's own per-account authenticated flag is set OR `<configDirPath>/.credentials.json` exists (claude's file fallback); needs-reauth requires both to be absent. The flag is best-effort (may drift on out-of-Logos login/logout).
- The bare entry being absent (user never ran plain `claude login`) is fine — accounts use their own entries.

**Acceptance criteria:**
- New tests in `Tests/LogosTests/AccountCredentialIsolationTests.swift`:
  - `ClaudeProcessConfig` for an account emits a non-empty `CLAUDE_CONFIG_DIR` equal to that account's `configDirPath`, emits `CLAUDE_SECURESTORAGE_CONFIG_DIR` equal to the same `configDirPath`, and never emits an empty `CLAUDE_SECURESTORAGE_CONFIG_DIR`.
  - `AccountManager.setActive` performs ZERO system-Keychain writes — verified with a `SystemKeychainBridge` test double that fails the test if `write`/`delete` is invoked.
  - Two distinct accounts produce two distinct `configDirPath` values (→ distinct claude entries).
  - An account lacking its per-dir credential is reported needs-reauth.
- Full `swift test` stays green.
- Manual (D5 gate, recorded on #12): terminal repro confirms distinct per-`CLAUDE_CONFIG_DIR` Keychain items.

**Scope boundaries:**
- In scope: `ClaudeProcessConfig` env emission; `Account.configDirPath`; removal of the swap from `AccountManager`; retirement of `SystemKeychainBridge` write/delete; needs-reauth flagging + minimal switcher indication; migration flagging; tests; CHANGELOG.
- Out of scope: `che-keychain` integration; sandboxing/entitlements; redesign of `AccountCredentialStore`; the OAuth login flow itself (delegated to `claude login`); any switcher UI work beyond the needs-reauth indicator.

## Risks / Trade-offs

- [claude's `CLAUDE_CONFIG_DIR`→service-hash mapping is version-pinned and reverse-engineered] → Treat as observed behavior, not a contract; the D5 empirical gate confirms it before code lands; re-verify on claude upgrades.
- [Migration could destroy the bare entry / break plain-terminal claude] → Hard rule: never delete or overwrite the bare entry; migration is mark-needs-reauth + re-login only.
- [`CLAUDE_SECURESTORAGE_CONFIG_DIR` inherited as empty would force the bare name and defeat isolation] → Explicitly ensure it is unset/controlled in the emitted environment; cover with a test assertion.
- [Existing users must re-login per account (one-time friction)] → Mitigated by a clear needs-reauth indicator and by leaving the bare entry working for the previously-active account until they re-auth.
- [Behavior change to multi-account swap] → Marked BREAKING (internal); no external API affected; tests pin the new no-write behavior.

## Migration Plan

1. On first launch of the new build, ensure each existing account's config dir (`<homeDirectoryPath>/.claude`) exists (no credentials written).
2. Mark each existing account needs-reauth unless a promptless credential signal is present (`<configDirPath>/.credentials.json` exists). The Logos authenticated flag starts unset for existing accounts (it is recorded going forward when the user authenticates an account through Logos).
3. For the previously-active account (whose creds are in the bare entry), offer a one-time re-login under its config dir via `claude login`; do NOT copy the bare entry's value with a Logos write.
4. Leave the bare `Claude Code-credentials` entry untouched so non-Logos `claude` keeps working.
5. After migration, `RealSystemKeychainBridge` no longer writes/deletes; it is retained read-only for the capture/import flow. The needs-reauth check does NOT read the Keychain (promptless flag + file signal only).
