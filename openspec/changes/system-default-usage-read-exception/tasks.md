<!--
ASSUMPTION: This change runs the propose -> apply chain (no separate archive step in
this invocation). The deliverable is the corrected published spec at
openspec/specs/account-credential-isolation/spec.md, so the apply phase publishes the
MODIFIED requirement delta into that live spec. Tasks below describe the published-spec
end state and its verification, not a code change (there is none).
-->

## 1. Publish the carved-out read clause to account-credential-isolation

- [x] 1.1 The published requirement "The shared bare Keychain entry is never mutated" in `openspec/specs/account-credential-isolation/spec.md` states a two-case read allowance: the Logos usage window MAY read the bare `Claude Code-credentials` entry READ-ONLY for the system-default account (which reuses `~/.claude`), while every isolated (convention) account uses its hash-suffixed per-directory service name and SHALL NOT read the bare entry. Verify: the requirement body contains both the system-default read allowance and the isolated-account hash-suffixed restriction, and `spectra validate system-default-usage-read-exception` passes.
- [x] 1.2 The mutation-ban wording is preserved byte-stable — the requirement's opening sentence ("Logos SHALL NOT delete or overwrite the bare `Claude Code-credentials` entry ...") and the "Usage refresh leaves the bare entry untouched" scenario are unchanged. Verify: `git diff` on the published spec shows no edit to the opening mutation-ban sentence or to the "Usage refresh leaves the bare entry untouched" scenario block.
- [x] 1.3 The formerly over-claiming scenario "The Logos usage window does not read the bare entry" is renamed and reframed so its THEN branch distinguishes the system-default row (bare service name, read-only) from isolated rows (hash-suffixed) and asserts no add/update/delete occurs. Verify: the published spec contains the reframed scenario with a per-account service-name example table, and no surviving scenario title claims the window "does not read the bare entry".

## 2. Confirm no behavioral regression

- [x] 2.1 [P] The shipped LogosUsage behavior stays locked in both directions with zero source change, confirming this is spec-only. Verify: `swift test --filter RegistryUsageModelTests` shows `systemDefaultReadsBareEntry` (bare service for the system-default row) and `neverReadsBareEntry` (hash-suffixed for isolated rows) green, and `git status --porcelain Sources/` reports no modification.
