## Why

The `account-credential-isolation` spec carries a normative read-restriction that shipped, tested behavior now directly contradicts, and the project's CLAUDE.md declares specs the overriding source of truth. The requirement "The shared bare Keychain entry is never mutated" states that "the Logos usage window SHALL NOT read the bare entry, because it renders registry accounts only and the default account is not a registry entry." Both halves are now false:

- **Premise invalidated by #54**: the system-default ("Main") account IS a registry entry — it reuses `~/.claude`. The justification "the default account is not a registry entry" no longer holds.
- **Behavior introduced by #55 (C1)**: `RegistryUsageModel` builds the system-default account's usage row with `isDefault: true`, whose Keychain lookup resolves to the bare `Claude Code-credentials` service name and reads it read-only to display Main's plan usage. This is asserted green by the `systemDefaultReadsBareEntry` test; the isolated-account path stays hash-suffixed (`neverReadsBareEntry`).

Reverting the code restores the "Main usage always empty" bug that #55 fixed, so the code is correct — the spec text is stale. This change closes the spec/behavior gap.

## What Changes

- **MODIFY** the requirement "The shared bare Keychain entry is never mutated" in `account-credential-isolation`: carve out a system-default exception in the READ clause. Isolated / convention accounts' usage reads stay hash-suffixed-only; the system-default account (a registry entry since #54 that reuses `~/.claude`) MAY have its usage window read the bare `Claude Code-credentials` entry READ-ONLY.
- **REFRAME** the scenario currently titled "The Logos usage window does not read the bare entry" — the title over-claims post-#55. Rename it and split its assertion: isolated rows resolve to hash-suffixed service names; the system-default row resolves to the bare service name, read-only.
- **PRESERVE verbatim** the mutation ban: the requirement's opening statement ("Logos SHALL NOT delete or overwrite the bare `Claude Code-credentials` entry ...") and the "Usage refresh leaves the bare entry untouched" scenario are NOT changed. The carve-out is a read allowance only; nothing weakens the write/delete prohibition.
- Cross-spec consistency: this aligns `account-credential-isolation` with `usage-display`, whose "Keychain service names follow claude's own derivation" requirement already permits the default account to use the bare service name. `usage-display` needs no change — it is already correct; only `account-credential-isolation` is brought into consistency with it.

## Non-Goals

- **No code change.** The shipped `RegistryUsageModel` / `ClaudeKeychain` behavior is already correct and locked by the `systemDefaultReadsBareEntry` (bare, for the system-default row) and `neverReadsBareEntry` (hash-suffixed, for isolated rows) tests in the LogosUsage test target. This change is spec-text only.
- **Not broadening the exception.** The carve-out is scoped strictly to the system-default account (`isDefault: true` / reuses `~/.claude`). Isolated convention accounts keep hash-suffixed-only reads — the isolation guarantee for them is unchanged.
- **Not touching the mutation ban.** The write/delete prohibition and its "byte-identical after refresh" scenarios stay byte-stable.
- **Not modifying `usage-display`.** It already permits the default-account bare read; it is referenced only to justify the consistency direction.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `account-credential-isolation`: the requirement "The shared bare Keychain entry is never mutated" changes its READ clause to permit the system-default account's usage window to read the bare entry read-only, while isolated accounts stay hash-suffixed and the mutation ban is preserved verbatim.

## Impact

- Affected specs: `account-credential-isolation` (modified — one requirement's read clause + one scenario). `usage-display` is referenced for consistency but not modified.
- Affected code: none. Existing regression guards in `Tests/LogosUsageTests/RegistryUsageModelTests.swift` (`systemDefaultReadsBareEntry`, `neverReadsBareEntry`) already lock the intended behavior in both directions and remain the behavioral anchor.
- User flow: none — the behavior shipped under #55; this only closes the documentation/spec gap.
