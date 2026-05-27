# Sub-plan E Retrospective — Multi-Account Architecture Gap

**Date**: 2026-05-27
**Status**: E delivered as infrastructure scaffold; **real multi-account switching does NOT work** because of a wrong assumption.

## What we built

Sub-plan E delivered 8 tasks of solid infrastructure:

| Layer | Status | Notes |
|-------|--------|-------|
| `Account` model + 5 tests | ✅ Works | Value type, validates labels |
| `AccountCredentialStore` (Keychain + InMemory) + 5 tests | ✅ Works | Our Logos-side Keychain entries at service `app.getlogos.logos.credentials` |
| `AccountManager` + 8 tests | ✅ Works | @Observable orchestrator, metadata in UserDefaults, creds via injected store |
| `ClaudeProcessConfig.account` HOME injection + 2 tests | ✅ Works | Sets `env["HOME"]` to per-account tree |
| `materializeHomeTree` writes `.credentials.json` with 0o600 | ✅ Works | Files appear at `~/.logos/accounts/<id>/.claude/.credentials.json` |
| `TerminalPaneView` + `NoActiveAccountBanner` | ✅ Works | UI shows correct state |
| `AccountSwitcherSheet` + ⌘K hotkey | ✅ Works | Add / select / remove accounts via UI |
| `FirstLaunchAccountImport` | ❌ No-op | See below |

**Cumulative tests**: 60 passing across 11 suites.

## What's broken

**Modern Claude Code stores OAuth credentials in macOS Keychain, NOT in `~/.claude/.credentials.json`.**

Verified on this machine:
```
$ ls ~/.claude/.credentials.json
ls: ... No such file or directory

$ security dump-keychain | grep -i 'Claude Code-credentials'
0x00000007 <blob>="Claude Code-credentials"
"acct"<blob>="che"
```

The Keychain entry is keyed by:
- **service**: `Claude Code-credentials`
- **account**: `$USER` (e.g., `che`)

This is **user-level state, not HOME-level state**. Consequences:

1. **`FirstLaunchAccountImport` never fires** — no `~/.claude/.credentials.json` exists to import from.
2. **`materializeHomeTree` writes a useless file** — claude reads Keychain, ignores the file we wrote.
3. **`HOME` env override does NOT switch claude's active account** — claude reads `Keychain[Claude Code-credentials][che]` regardless of `$HOME` value. So switching active account in Logos UI → spawning claude with different HOME → claude still uses the same Keychain credentials.

## Why the plan was wrong

The original design doc (§ 8.4) cited "option β: HOME env override per subprocess" as the chosen mechanism, based on assumption that claude reads `$HOME/.claude/.credentials.json`. This was an outdated mental model from an earlier Claude Code version, or possibly from a different CLI entirely.

**Lesson**: I should have run `strings $(which claude) | grep -i 'credential\|keychain\|.claude/'` BEFORE writing the plan, to verify the actual credential mechanism.

## Path forward — Sub-plan E.2 (real Keychain swap)

The actual mechanism that would work:

```
                ┌─────────────────────────────────────────┐
                │ macOS Keychain (system)                  │
                │   service: "Claude Code-credentials"     │
                │   account: $USER                         │
                │   value:   <one set of OAuth tokens>     │
                └────────────────┬────────────────────────┘
                                 │
                                 │  read by claude
                                 ▼
                          [claude subprocess]
                                 │
                                 │  on Logos account-switch:
                                 ▼
              ┌─────────────────────────────────────────────┐
              │ Logos-managed Keychain entries               │
              │   service: "app.getlogos.logos.credentials"  │
              │   account: <our internal account id>         │
              │   value:   <stored OAuth tokens per account> │
              └──────┬──────────────────────────┬───────────┘
                     │                          │
                     │ COPY active → Claude     │ COPY Claude → backup
                     │  before spawn            │  before COPY in
                     ▼                          │
        [overwrites system Claude entry]        │
                                                │
                                          on add-account
```

**The swap mechanism**:
1. **Capture step (add account)**: When user adds account "work", read current `Keychain[Claude Code-credentials][$USER]` → store as `Keychain[app.getlogos.logos.credentials][<account_id>]`.
2. **Switch step (set active)**: Read `Keychain[app.getlogos.logos.credentials][<active_id>]` → write to `Keychain[Claude Code-credentials][$USER]`.
3. **Spawn step (start claude)**: claude reads the (now updated) system Keychain entry, gets the active account's tokens.

**Risks of this approach**:
- **Race condition** if user runs claude outside Logos while Logos has an account switched in. They'll be on whatever Logos last wrote. Acceptable for v1 (Logos users won't run claude elsewhere often).
- **OAuth refresh**: when claude refreshes tokens, it overwrites the system Keychain entry. Logos needs to detect this and update the per-account backup. Requires periodic read-back.
- **Multiple Logos windows simultaneously**: if window A is on "work" and window B is on "personal" and both spawn claude in parallel, they fight over the system Keychain entry. Solution: serialize spawns OR scope per-spawn via something else (env var?) — needs investigation.

**The simpler approach we could ship first**: only allow ONE active session. Block opening a second Logos window until first is closed. Trade UX for correctness.

## Recommendation

Ship Sub-plan E as it is — the infrastructure (model + UI + store + manager) is solid and reusable. **Document that "real account switching" requires Sub-plan E.2 (Keychain swap)**. Until E.2 ships:
- UI works and accounts persist in our store
- Switching active does nothing functionally to claude
- FirstLaunchAccountImport gracefully does nothing

For users who only want ONE account: Logos works fine (they never switch, the active account's credentials are irrelevant since claude reads system Keychain anyway). The killer feature is delayed until E.2.

## Sub-plan E.2 sketch

```
E.2-Task 1: SystemKeychainBridge — read/write Keychain[Claude Code-credentials][$USER]
E.2-Task 2: AccountManager.addByCapturingCurrent() — capture step
E.2-Task 3: AccountManager.setActive() also swaps system Keychain — switch step
E.2-Task 4: First-launch import via SystemKeychainBridge (no more file path)
E.2-Task 5: Drop materializeHomeTree (no longer needed)
E.2-Task 6: Drop HOME override in ClaudeProcessConfig (no longer needed)
E.2-Task 7: Tests via mocked SystemKeychainBridge
E.2-Task 8: Smoke + screenshot showing real account switch in claude
```

Estimated 4-6 hours after Logos team commits to E.2.

## What this means for downstream sub-plans

- **F (file explorer)**: independent; not affected
- **G (PDF live render)**: independent; not affected
- **H (Settings UI)**: AccountsTab will work to LIST accounts; switching won't have functional effect until E.2

So E.2 can ship after F/G/H without blocking.
