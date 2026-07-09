## MODIFIED Requirements

### Requirement: Registry mutations validate labels

Account creation and rename SHALL validate labels against a two-dimensional size bound. A label SHALL first be trimmed of leading and trailing whitespace and newlines (the `.whitespacesAndNewlines` set — the same set on every path, so a newline-bearing label decoded from disk trims identically to one typed into the UI). A trimmed label MUST be non-empty, MUST NOT exceed 30 extended grapheme clusters, MUST NOT exceed 256 UTF-8 bytes, and MUST NOT duplicate another account's label. The grapheme cap and the byte cap are independent: a label within 30 grapheme clusters that still carries more than 256 UTF-8 bytes (a combining-mark "zalgo" cluster, or a long ZWJ emoji sequence) MUST be rejected, because grapheme count alone does not bound the persisted byte size and an unbounded label can push the whole index past its file-size cap and be dropped on load.

On the mutation path (create, rename) an over-budget label SHALL be rejected with a label-too-long error. On the load-time repair path (index normalization) an over-budget label SHALL instead be silently clamped rather than rejected: the clamp SHALL truncate on a grapheme-cluster boundary — accumulating whole clusters until the next would exceed 256 UTF-8 bytes — so a repaired label is never left with a split grapheme cluster or mojibake. When the load-time repair uniquifies two isolated accounts whose labels collide at or near the byte cap, it SHALL append the disambiguating suffix so the suffix itself survives the byte cap — clamping the base label to leave room for the suffix rather than letting the byte clamp truncate the suffix away — so the two accounts retain DISTINCT persisted labels rather than silently remaining duplicates. Renaming an account to its own current label SHALL succeed. A rename SHALL preserve the account id and createdAt, so it never moves the config directory or invalidates a login.

#### Scenario: Label validation outcomes

- **WHEN** the user submits a label for create or rename
- **THEN** the registry accepts or rejects it per the validation rules

##### Example: validation cases

| Input | Existing labels | Operation | Expected |
| ----- | --------------- | --------- | -------- |
| "" | (any) | create | rejected: empty label |
| 31 grapheme clusters | (any) | create | rejected: label too long |
| 1 base char + 4000 combining marks (1 grapheme cluster, ~8 KB UTF-8) | (any) | create | rejected: label too long (over the 256-byte cap despite being 1 grapheme) |
| "work" | work, personal | create | rejected: duplicate label |
| "work" | work (same account) | rename | accepted (own label) |
| "Work 2" | work, personal | rename | accepted, id and createdAt preserved |

#### Scenario: Load-time repair clamps an over-budget label on a grapheme boundary

- **WHEN** the registry loads and normalizes an index whose label is within 30 grapheme clusters but exceeds 256 UTF-8 bytes
- **THEN** normalization clamps the label to at most 256 UTF-8 bytes by dropping whole trailing grapheme clusters
- **AND** the persisted label round-trips as valid `Character`s (no cluster is split mid-scalar)
- **AND** an index whose labels are already within both caps is not rewritten by normalization (the net-change convergence from the prior label-repair pass is preserved, so a clean index is never re-saved on load)

##### Example: byte-cap clamp on a grapheme boundary

- **GIVEN** a persisted label of 30 ZWJ family-emoji clusters (each 25 UTF-8 bytes = 750 bytes total, but only 30 grapheme clusters, so it passes the grapheme cap)
- **WHEN** the registry loads and normalizes
- **THEN** the label is clamped to the largest whole-grapheme prefix whose utf8.count ≤ 256 — 10 family-emoji clusters (250 bytes); the 11th would reach 275 bytes and is dropped whole
- **AND** no family-emoji cluster is left partially truncated (no dangling ZWJ or lone scalar)

#### Scenario: Load-time uniquify keeps the disambiguating suffix under the byte cap

- **WHEN** the registry loads and normalizes an index in which two isolated accounts share a label at or near the 256-UTF-8-byte cap (e.g. a single grapheme cluster of exactly 256 bytes)
- **THEN** normalization keeps the earlier occurrence's label and appends a `" (recovered)"` disambiguator to the later one, clamping the base first so the suffix is never truncated by the byte cap
- **AND** the two accounts end with DISTINCT persisted labels whose disambiguating suffix is visible (the duplicate is not silently preserved by a stripped suffix)
- **AND** the repaired index converges — a subsequent load does not rewrite it, because the byte clamp is idempotent and the realized (post-clamp) labels are compared for the net change

##### Example: suffix survives at the byte cap

- **GIVEN** two isolated accounts persisted with the identical label of a single grapheme cluster of exactly 256 UTF-8 bytes
- **WHEN** the registry loads and normalizes
- **THEN** the first keeps the 256-byte label and the second is stored as a distinct label carrying a visible `(recovered)` suffix, each within the 256-byte cap
- **AND** reloading the repaired index is a no-op (no re-save)
