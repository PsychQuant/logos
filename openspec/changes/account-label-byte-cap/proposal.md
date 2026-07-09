## Why

Every account-label length gate in `LogosAccounts` bounds Swift `Character` (extended grapheme cluster) count, never UTF-8 byte size. A single grapheme cluster can carry an unbounded number of combining scalars (a "zalgo" base char + thousands of combining marks, or a long ZWJ emoji sequence), so a 30-grapheme label can smuggle ~300 KB of scalars past all gates and into the persisted `accounts/index.json`. This was empirically verified during #59 round-1 verify (the #59 grapheme clamp removed 0 bytes from a fat cluster) and is reachable through the ordinary rename UI — no crafted JSON needed.

The stake is not just a bloated file: `AccountRegistry.load()` enforces a whole-file `maxIndexBytes = 1_048_576` cap and, on breach, returns `[]` — it drops the ENTIRE registry ("starting empty, file preserved", #61). Unbounded per-label bytes can push the whole index past 1 MB, so the missing per-label bound can silently WIPE ALL accounts on next launch. The per-label byte cap in this change is the upstream fix that keeps #61's whole-file cap from firing as data loss.

## What Changes

- Add one shared label-normalization helper on `Account` (single source of truth) with: a consistent trim set (`.whitespacesAndNewlines` — the superset), an empty→placeholder policy for repair paths, the existing 30-grapheme cap, AND a NEW grapheme-cluster-aware UTF-8 byte cap. Split into a pure normalizing core (clamps) plus a throwing wrapper for the user-facing mutation gate.
- Introduce a named constant `maxLabelUTF8Bytes = 256` (see ASSUMPTION below) bounding the persisted byte size of any label.
- Grapheme-safe truncation: the byte clamp accumulates whole `Character` clusters until the next would exceed the byte budget — never a raw `utf8.prefix` / scalar cut (which yields mojibake / a split cluster).
- Wire the helper into all four label sites so they share one definition of "a valid, bounded, trimmed label":
  - `Account.validate(label:)` — mutation gate: throws the existing `ValidationError.labelTooLong` when the trimmed label exceeds either cap (30 graphemes OR 256 UTF-8 bytes).
  - `Account.init(label:)` — construction: silently clamps to the 256-byte cap only, on a grapheme boundary (no length check exists today). Deliberately NOT grapheme-capped: the uniquify sweep constructs a `"<label> (recovered)"` label that can exceed 30 graphemes while carrying few bytes, and relies on `init` preserving the suffix — a grapheme clamp here would strip it and reopen the collision the sweep just resolved. The grapheme cap is re-imposed on load by `normalize()`'s cleanup pass and at the mutation gate by `validate`.
  - `AccountRegistry.normalize()` phase 3 — load-time repair: silently clamps to both caps.
  - `Account.init(from:)` decode: the disk-bypass path; its labels are repaired by `normalize()` on load. Decode-path coverage is asserted by tests through the decode/normalize repair path.
- **BREAKING (user-visible)**: a label previously accepted/persisted (within 30 graphemes but over 256 UTF-8 bytes) is now rejected on create/rename or silently clamped on load. Recorded in CHANGELOG.
- Resolve the trim-set DRIFT: `Account.validate` / `Account.init` currently trim `.whitespaces` while `normalize()` phase 3 trims `.whitespacesAndNewlines`; the shared helper unifies on `.whitespacesAndNewlines` (a newline-bearing label decoded from disk now trims identically on every path).
- Preserve #59's net-change convergence in `normalize()` — the new byte clamp folds into the end-of-pass `labelsBefore` comparison so a repaired index writes once and is never re-saved on subsequent loads.
- Update the `account-registry` spec's "Registry mutations validate labels" requirement (normative MUST text + example table) to state both caps, the `.whitespacesAndNewlines` trim set, and the throw-vs-clamp split between the mutation path and the load-repair path.

## Non-Goals

- **No client-side UI clamp.** The two `TextField` entry points (rename, add) gain no `.onChange` character/byte limiter; the entire bound stays server-side in the shared helper. Adding a UI affordance is out of scope.
- **No new `ValidationError` case.** The mutation gate reuses `labelTooLong` rather than adding `labelTooLarge`; a new enum case is a breaking change for exhaustive `switch` sites and is not required to close the bug. Rejected to keep the API surface stable.
- **No change to the 30-grapheme cap or the placeholder string.** The grapheme cap stays at 30; the empty→placeholder policy keeps the existing `(unnamed)` placeholder.
- **No change to the #61 whole-file `maxIndexBytes` / `maxAccounts` caps.** This change is strictly the upstream per-label bound; the whole-file cap and its load-empty-preserve-bytes behavior are unchanged.
- **ASSUMPTION — byte budget = 256 UTF-8 bytes.** The diagnosis names `utf8.count <= 256` as its concrete anchor. Rationale: 256 accommodates all realistic label content — 30 BMP CJK graphemes ≈ 90 bytes (BMP CJK is 3 UTF-8 bytes each), 30 flag emoji = 240 bytes, 30 simple emoji = 120 bytes — while rejecting pathological ZWJ chains (30 family emoji ≈ 750 bytes) and the ~300 KB zalgo attack (a ~1200× reduction). The diagnosis flags the tension: a budget too tight rejects legitimate emoji/CJK labels, too loose leaves attack headroom; 256 sits above every realistic label and far below the attack. With `maxAccounts = 500`, a 256-byte label cap keeps a full index (500 × ~406 bytes ≈ 203 KB) well under the 1 MB whole-file cap, so the per-label and whole-file bounds are mutually consistent.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `account-registry`: the "Registry mutations validate labels" requirement gains a UTF-8 byte-size dimension. A trimmed label MUST NOT exceed 256 UTF-8 bytes in addition to the existing 30-grapheme cap; the trim set is normatively `.whitespacesAndNewlines`; the mutation path throws on breach while the load-time repair path silently clamps on a grapheme-cluster boundary.

## Impact

- Affected specs: `account-registry` (modified)
- Affected code:
  - Modified:
    - `Sources/LogosAccounts/Account.swift` — new shared normalization helper + `maxLabelUTF8Bytes` constant; `validate(label:)` and `init(label:)` route through it.
    - `Sources/LogosAccounts/AccountRegistry.swift` — `normalize()` phase 3 routes through the shared helper; byte clamp folds into the net-change comparison.
    - `openspec/specs/account-registry/spec.md` — "Registry mutations validate labels" requirement text + example table.
    - `Tests/LogosAccountsTests/AccountRegistryTests.swift` — normalize/decode repair-path byte-cap tests + net-change convergence test.
    - `Tests/LogoSwitchTests/AccountTests.swift` — mutation-path (validate/init) byte-cap + grapheme-safety tests.
    - `CHANGELOG.md` — user-visible entry (a formerly-accepted fat label is now rejected/clamped).
  - New: (none)
  - Removed: (none)
