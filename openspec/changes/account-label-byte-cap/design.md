## Context

`LogosAccounts` bounds account-label length by Swift `Character` (extended grapheme cluster) count at four sites, none of which bounds UTF-8 byte size. A single grapheme cluster can hold an unbounded number of combining scalars, so a 30-grapheme "zalgo" label carries ~300 KB into the persisted `accounts/index.json`. The whole-file cap (`maxIndexBytes = 1_048_576`, #61) drops the ENTIRE registry to `[]` on breach, so unbounded labels are not merely bloat — they are a silent-data-loss vector on next launch. The four sites also disagree on the trim set (`.whitespaces` vs `.whitespacesAndNewlines`), giving two definitions of "trimmed".

This design is warranted because the change is security-sensitive (a persisted-size boundary), carries a decision-heavy grapheme-safe truncation algorithm, has an ordering dependency (the shared helper must exist before its consumers), and modifies published normative spec text.

## Goals / Non-Goals

Goals:
- One shared label-normalization helper on `Account` as the single source of truth for trim set, emptiness, grapheme cap, and a new UTF-8 byte cap.
- A grapheme-cluster-safe byte clamp that never splits a cluster.
- All four label sites route through the shared helper; the trim-set drift is resolved.
- The new byte clamp folds into `normalize()`'s existing net-change convergence (no re-save on every load).

Non-Goals:
- No client-side UI clamp (bound stays server-side).
- No new `ValidationError` case (reuse `labelTooLong`).
- No change to the 30-grapheme cap, the `(unnamed)` placeholder, or #61's whole-file caps.

## Decisions

### Shared normalizing core plus a throwing validate wrapper

Add a single pure function that produces a normalized, bounded label (trim → placeholder-if-empty → grapheme clamp → byte clamp) and a thin throwing wrapper that `validate(label:)` calls. The core CLAMPS (used by `init(label:)` and `normalize()` phase 3); the wrapper measures the trimmed label and THROWS when it exceeds either cap (used by the user-facing mutation gate). Both share the exact same trim set and cap constants, so "what a valid, bounded label is" is defined once. Alternative rejected: duplicating the trim+cap logic per site (the status quo) — it is precisely what produced the `.whitespaces`/`.whitespacesAndNewlines` drift and the missing byte bound.

### Grapheme-cluster-aware UTF-8 byte truncation

The byte clamp iterates the label by `Character`, accumulating a running UTF-8 byte count, and stops before appending the first cluster that would push the total over `maxLabelUTF8Bytes`. It returns the accumulated prefix. This never cuts mid-scalar or mid-cluster, so the result is always a sequence of whole `Character`s (no mojibake, no dangling ZWJ). Alternative rejected: `String(decoding: label.utf8.prefix(n), as: UTF8.self)` — a raw byte prefix can land inside a multi-byte scalar or inside a ZWJ sequence, producing a replacement char or a broken cluster.

### 256-byte UTF-8 budget as a named constant

Introduce `static let maxLabelUTF8Bytes = 256` on `Account`. 256 accommodates every realistic label (30 BMP CJK ≈ 90 bytes, 30 flag emoji = 240 bytes, 30 simple emoji = 120 bytes) while rejecting pathological ZWJ chains (30 family emoji ≈ 750 bytes) and the ~300 KB zalgo attack (~1200× reduction). With `maxAccounts = 500`, a 256-byte label cap keeps a full index (500 × ~406 bytes ≈ 203 KB) well under the 1 MB whole-file cap, so the per-label and whole-file bounds are mutually consistent. Alternatives considered: 120 bytes (tighter, but rejects legitimate flag-emoji labels); no cap on scalar count instead of bytes (bytes are what the whole-file cap measures, so bytes are the right unit).

### Reuse labelTooLong rather than adding a ValidationError case

The over-byte mutation rejection throws the existing `ValidationError.labelTooLong`. A new case (e.g. `labelTooLarge`) would be a breaking enum change for every exhaustive `switch` — including the two UI catch sites in `AccountSwitcherSheet`. The user-facing distinction (too many characters vs too many bytes) is not worth an API break; both are "the label is too big". Alternative rejected: a distinct case — deferred as unnecessary surface.

### Unify the trim set on .whitespacesAndNewlines

The shared helper trims `.whitespacesAndNewlines` (the superset). This changes `validate` / `init(label:)` from `.whitespaces`, so an interior-or-trailing-newline label now trims on every path identically. This is the intended normative behavior (a newline in a persisted label was only ever reachable through the decode path, which `normalize()` already trimmed with the newline-inclusive set).

### Construction byte-clamps only (init preserves grapheme length)

Discovered on contact with the code: `AccountRegistry.normalize()`'s uniquify sweep (#59) constructs an `Account` with a `"<label> (recovered)"` label that can exceed 30 grapheme clusters while carrying only tens of bytes, and #59's exact-cap-collision convergence RELIES on `init` storing it intact (the cleanup clamp and the uniquify suffix oscillate to a net-stable label, so the index writes once and never re-saves). If `init` grapheme-clamps, it strips the `" (recovered)"` suffix, reopens the label collision, and breaks that convergence (a pre-existing #59 test fails). So `init(label:)` applies the BYTE cap only, not the grapheme cap. This is safe because the grapheme cap is not a persisted-size boundary (bytes are), and every real over-length gate still holds: `validate` throws on >30 graphemes at the mutation boundary, and `normalize`'s cleanup pass grapheme-clamps on load. `init`'s byte clamp remains as defense-in-depth so no `Account` can ever hold unbounded bytes even if a future caller bypasses `validate`. Alternative rejected: keep `init` grapheme-clamping and rewrite #59's uniquify to produce an in-cap label — out of scope, changes #59's asserted behavior, and grapheme-clamping in `init` buys no security.

### Fold the byte clamp into normalize's net-change comparison

`normalize()` phase 3 compares `labelsBefore` (the pre-pass label snapshot) against the post-pass labels and sets `changed` only on a net difference, so a repaired index writes once and never re-saves. The byte clamp runs inside the same per-index loop that already produces the clamped label, so its effect is captured by the existing end-of-pass comparison — it MUST NOT introduce a separate per-step `changed = true`, or a clean-but-fat index would re-save on every load (the exact regression #59's verify pinned).

## Implementation Contract

- **Observable behavior — mutation path**: `Account.validate(label:)` and every caller (`AccountRegistry.create`/`add`/`rename`, `AccountManager.createAccount`) throw `ValidationError.labelTooLong` when the trimmed label exceeds 30 grapheme clusters OR 256 UTF-8 bytes. A label within both caps is accepted unchanged (after trimming).
- **Observable behavior — construction**: `Account(label:)` stores a label trimmed with `.whitespacesAndNewlines` and clamped to the BYTE cap (256) on a grapheme boundary. It does NOT grapheme-clamp (see "Construction byte-clamps only" below) — the 30-grapheme cap is enforced by `validate` (mutation gate) and by `normalize` on load, not at construction.
- **Observable behavior — load repair**: `AccountRegistry.normalize()` clamps any persisted label over either cap to a whole-grapheme prefix with `utf8.count <= 256`; a persisted index already within both caps is NOT rewritten.
- **Interface / data shape**: a new `static let maxLabelUTF8Bytes = 256` on `Account`; a shared normalization function on `Account` (pure, `Sendable`-safe, no I/O). No change to the `Account` stored properties or the `index.json` schema.
- **Error/failure mode**: mutation over-budget → thrown `ValidationError.labelTooLong` (existing case). Load-repair over-budget → silent clamp + a single net save.
- **Acceptance criteria**: the tests named in tasks.md pass — zalgo, ZWJ, flag, CJK, and mid-cluster-boundary labels through BOTH the mutation path (throws) and the decode/normalize path (clamps); every persisted label asserts `utf8.count <= 256` AND round-trips as valid `Character`s; a clean in-budget index asserts byte-identical after normalize.
- **In scope**: `Sources/LogosAccounts/Account.swift`, `Sources/LogosAccounts/AccountRegistry.swift`, the `account-registry` spec, the two named test files, `CHANGELOG.md`.
- **Out of scope**: UI TextField clamps, the `ValidationError` enum shape, the 30-grapheme cap value, #61's whole-file caps, any other spec.

## Risks / Trade-offs

- [Naive byte truncation splits a grapheme cluster → mojibake] → the clamp is cluster-aware (accumulate whole `Character`s); tests assert the result round-trips as valid `Character`s.
- [Trim-set change from `.whitespaces` to `.whitespacesAndNewlines` is a minor normative change to the public mutation gate] → documented in the spec and CHANGELOG; the only affected input is an interior/trailing-newline label, which was already newline-trimmed on the decode/normalize path.
- [Byte clamp re-saves the index on every load if not folded into net-change convergence] → the clamp stays inside the existing loop and relies on the existing end-of-pass `labelsBefore` comparison; a dedicated test asserts a clean fat-but-in-budget index is byte-unchanged after load.
- [Budget too tight rejects legitimate emoji/CJK labels; too loose leaves attack headroom] → 256 is calibrated above every realistic 30-grapheme label and ~1200× below the attack; recorded as an ASSUMPTION in the proposal.

## Migration Plan

No data migration. Existing in-budget labels are unaffected. A persisted over-budget label (only reachable via a hand-edited or attacker-written index) is clamped in memory on the next load and written once. Rollback is a straight revert of the two source files and the spec; no persisted-format change to undo.

## Open Questions

(none — the byte budget is fixed at 256 per the proposal ASSUMPTION; the throw-vs-clamp split, trim set, and truncation algorithm are all decided above.)
