## Context

Logos hosts Claude Code terminals with per-account isolation via CLAUDE_CONFIG_DIR (one config dir per account under the Logos accounts root, currently the .logos/accounts directory in the user home). Its account module (LogoSwitch) deliberately owns NO credential capability: a red-line audit test scans LogoSwitch sources and forbids Security imports, SecItem tokens, and security(1) shell-outs — auth belongs to claude itself.

MultiStats is a sibling repo: a read-only multi-account usage viewer that discovers accounts by scanning the same Logos config-dir convention, reads each account's OAuth token from the Keychain (read-only), calls the usage endpoint, and renders per-account remaining-quota bars.

Pain points driving the merge:
- The config-dir convention is duplicated in both repos (Account.configDirPath in logos; AccountDiscovery scan paths in MultiStats).
- Account identity is split: Logos owns labels in UserDefaults (per-app, invisible to MultiStats); MultiStats reads emails from each account's config JSON (invisible to Logos).
- The maintainer's product decision: Logos should consume a single shared account registry and display usage natively; MultiStats remains only as a thin standalone viewer.

## Goals / Non-Goals

**Goals:**

- One source of truth for the account list, labels, and config-dir convention, shared by the Logos app and the standalone viewer (file-based registry, not per-app UserDefaults).
- Usage display inside Logos (a dedicated window) without weakening the credential red line: keychain reads stay confined to one small audited target.
- Preserve MultiStats git history and its open hardening issues.
- LogoSwitch's published red line (Foundation-only, structurally incapable of credential access) remains intact.

**Non-Goals:**

- No login, token refresh, or any credential write, ever — auth remains claude's own job end to end (existing #34 stance, unchanged).
- No account switching from the usage window; usage UI is display-only.
- Not a general multi-tool monorepo migration; only MultiStats merges in.
- No support for arbitrary non-Logos CLAUDE_CONFIG_DIR locations in this change (tracked separately if wanted).
- No git submodule and no cross-repo SPM remote dependency — those alternatives were evaluated and rejected in favor of in-repo targets (submodule pays both repos' costs with neither's benefits once the product identity is "Logos components"; a remote SPM dependency adds release/versioning overhead with no remaining independent audience).

## Decisions

### Decision 1: In-repo targets over submodule or remote SPM dependency

MultiStats code lands as first-class targets of the logos package. Rationale: its only audience is Logos users (discovery is keyed to the Logos convention), so an independent release cadence has no consumer; in-repo targets give atomic cross-cutting commits, one issue tracker, one CI. Audit-boundary value formerly provided by the repo boundary is preserved by target boundaries plus red-line audit tests. Alternatives: submodule (rejected: dependency-management by hand, clone friction, split history for no gain), SPM remote dependency (rejected: forces version-bump round-trips for what is now internal evolution).

### Decision 2: Target layering — LogosAccounts / LogosUsage / MultiStats executable

- LogosAccounts (library, Foundation-only): Account model, config-dir convention, filesystem discovery, config-JSON identity parsing, registry mutations (create/rename/remove), and file-based persistence. No Security, no CryptoKit needs beyond none — pure Foundation.
- LogosUsage (library): StoredCredentials, Keychain service-name derivation (CryptoKit SHA-256), read-only SystemKeychainReader, UsageClient, AccountUsageModel. Depends on LogosAccounts. The ONLY target in the package allowed to import Security.
- MultiStats (executable): thin shell + SwiftUI views over LogosUsage; retained so the standalone one-window viewer keeps existing.
- Dependency edges: LogoSwitch -> LogosAccounts; Logos app -> LogosAccounts + LogosUsage + LogoSwitch; MultiStats -> LogosUsage.
Rationale: the split exactly mirrors the risk gradient — registry code is credential-free and broadly consumable; keychain-touching code is small, read-only, and singly-audited. Alternative (single merged target): rejected, it would put Security inside everything that links accounts.

### Decision 3: Registry persistence moves to a shared JSON index file with one-time UserDefaults migration

UserDefaults is per-app (bundle-scoped), so a registry living there can never be shared across two executables. The registry persists to an index JSON file at the accounts root (accounts array: id, label, createdAt; written atomically via write-to-temp + rename). Active-account selection does NOT move — it is launcher UI state and stays in Logos-local UserDefaults. Migration: on first load, if the index file is absent and the legacy UserDefaults key logos.accounts holds data, decode it, write the index file, and leave the legacy key in place (read-fallback only, never written again) so downgrade remains harmless. Concurrency: last-write-wins with atomic replace is sufficient — writes happen only on explicit user actions (create/rename/remove), which are rare and human-paced. Alternatives: app-group UserDefaults (rejected: requires entitlements/signing coupling for a plain JSON list), SQLite (rejected: overkill for tens of records).

### Decision 4: Red-line audit extends by scope, not by exception

The existing RedLineAuditTests for LogoSwitch stay byte-for-byte in spirit (scan sources, forbid Security/SecItem/security(1) tokens outside comments). Two additions: (a) the same forbidden-token scan applies to Sources/LogosAccounts and Sources/Logos (the app), so the app cannot grow ad-hoc keychain code; (b) a scope test asserts that within the whole package, only Sources/LogosUsage and Sources/MultiStats may import Security — and a read-only test forbids SecItemAdd/SecItemUpdate/SecItemDelete tokens everywhere including LogosUsage itself. Rationale: the isolation story changes from "this repo never touches credentials" to "credential reads exist in exactly one audited, structurally read-only target"; tests make that invariant survive future contributors.

### Decision 5: History-preserving subtree merge

The MultiStats repo merges in with git subtree (prefix-based), keeping its commit history reachable in the logos repo. File moves into the target layout happen in follow-up commits inside logos so blame chains stay intact. Alternative (copy files in one commit): rejected, loses provenance for ~800 lines of reviewed credential-adjacent code whose review history is exactly what we want auditable.

### Decision 6: Logos usage window is a consumer, not a discoverer

The Logos usage window feeds the registry's account list (which Logos already owns in memory) into AccountUsageModel; it does not run filesystem discovery. Discovery remains for the standalone executable, which has no registry-owning host. Rationale: one authoritative account list inside Logos; discovery-vs-registry drift becomes impossible in-app.

## Implementation Contract

**Behavior:**

- Logos gains a "Usage" window listing every registered account with label, identity (email when known), plan-usage window consumption, and token-expired state. Refresh is manual plus on-window-open. Display-only: no switch, no login, no mutation.
- The standalone MultiStats executable builds from the logos package and behaves as today (discovery-based, default account plus Logos-convention accounts).
- Account create/rename/remove in Logos persists to the shared index file; a subsequent launch of either executable observes the same list. Legacy users' accounts survive via the one-time migration.
- LogoSwitch consumers see registry types re-exported/relocated from LogosAccounts; launcher state API (active selection, needsReauth, spawn glue) stays on AccountManager.

**Interface / data shape:**

- Index file: JSON object with a version field (integer, initially 1) and an accounts array of {id: string, label: string, createdAt: ISO-8601 date}; location: the accounts root index file (accounts/index.json under the Logos data directory in the user home). Atomic replace on write.
- LogosAccounts public surface: Account (model), AccountRegistry (load/save/create/rename/remove, duplicate-label validation preserved), AccountDiscovery (filesystem scan), ConfigParser (identity from config JSON).
- LogosUsage public surface: KeychainCredentialsReader (read-only), UsageClient, AccountUsageModel (per-account load states). Keychain service-name derivation stays: default account uses the bare Claude Code credentials service; per-dir accounts use the SHA-256(path) 8-hex-prefix suffix.

**Failure modes:**

- Unreadable/corrupt index file: registry starts empty but does NOT overwrite the corrupt file until the first explicit user mutation; a log notice records the parse failure. (Silent data destruction is the failure being designed against.)
- Keychain read denied or absent: that account renders as "no credentials" state; no retry storm, no prompt loop.
- Usage endpoint non-200: per-account error state, other accounts unaffected.
- Migration failure (undecodable legacy data): registry starts empty with a log notice; legacy UserDefaults data is never deleted.

**Acceptance criteria:**

- All existing LogoSwitch tests pass unchanged, including RedLineAuditTests.
- New red-line tests: forbidden-token scan green over Sources/LogosAccounts and Sources/Logos; package-wide scope test proves Security imports exist only in LogosUsage (and MultiStats executable if its views need none, tighten to LogosUsage only); write-token scan (SecItemAdd/Update/Delete) green over the entire package.
- Registry round-trip test: create/rename/remove persists to a temp index file and reloads identically; migration test: legacy UserDefaults fixture produces the same accounts in the index file.
- MultiStatsCore's existing unit tests (keychain parsing, service-name derivation, discovery filtering) pass relocated under the new target names.
- Manual: swift build produces Logos and MultiStats executables; the Logos usage window lists the same accounts as Settings -> Accounts.

**Scope boundaries:**

- In scope: subtree merge, target restructure, registry extraction + file persistence + migration, red-line test extension, Logos usage window, issue transfer + old-repo archive.
- Out of scope: menu-bar app form, auto-refresh scheduling/polling policy tuning, MultiStats hardening issues themselves (transferred, then addressed separately), any credential write path, per-project cost breakdowns from local JSONL.

## Risks / Trade-offs

- [Two processes write the index file concurrently] → writes are rare, human-initiated, atomic-replace; last-write-wins accepted and documented. The standalone viewer performs no registry writes in this change (read-only consumer), which removes the realistic collision pair entirely.
- [LogoSwitch gains its first internal dependency, diluting "depends on nothing"] → LogosAccounts is Foundation-only and covered by the same red-line scan; the published invariant that matters (no credential capability) is unchanged and now test-enforced across both targets.
- [Subtree merge pollutes logos history with scaffold commits] → accepted; provenance of credential-adjacent code outweighs log noise. Merge commit message documents the mapping.
- [First-run Keychain prompt stacking (transferred MultiStats issue) now surfaces inside Logos] → usage window serializes first-load credential reads per account (bounded concurrency of 1 on first authorization pass); the transferred issue tracks the deeper fix.
- [BREAKING LogoSwitch API move breaks external consumers] → LogoSwitch has no known external consumers yet; the break is documented in the release notes of the next tag.

## Migration Plan

1. Subtree-merge MultiStats into the logos repo under an incoming prefix; land target restructure commits (files move to Sources/LogosAccounts, Sources/LogosUsage, Sources/MultiStats).
2. Land registry extraction in LogoSwitch (AccountManager delegates to AccountRegistry) behind passing tests, including the UserDefaults -> index-file migration.
3. Land red-line test extension; CI green gate.
4. Add the Logos usage window.
5. Transfer MultiStats open issues to logos (gh issue transfer), update the MultiStats README to point at logos, archive the MultiStats repo.
Rollback: steps 1–4 are ordinary commits on a change branch (worktree flow) — revert the branch. Step 5 is reversible (unarchive; issues stay transferred).

## Open Questions

- Window vs. sidebar panel for usage display inside Logos (default assumption: separate window, matching the existing Settings window pattern).
- Whether the standalone MultiStats executable should read labels from the index file when present (nice-to-have; default assumption: yes, trivially, since LogosAccounts ships both discovery and registry).
