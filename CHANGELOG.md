# Changelog

All notable changes to Logos are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **The keychain authorization dialog no longer reappears on every launch of a dev build**
  ([#101](https://github.com/PsychQuant/logos/issues/101)). `make bundle` signed ad-hoc, whose
  designated requirement is anchored to the CDHash — different on every rebuild — so the 永遠允許
  grant for the status bar's read-only usage lookup (claude CLI's credential items) could never
  persist. Dev bundles now sign with the machine's Apple Development certificate (requirement
  anchored to identifier + certificate chain, stable across rebuilds): authorize once, never asked
  again. Machines without the certificate fall back to ad-hoc with a visible warning. Credentials
  stay in the keychain — nothing about credential storage or the read-only access pattern changed.

- **Sidebar can no longer be permanently lost** ([#100](https://github.com/PsychQuant/logos/issues/100)).
  Dragging the sidebar below its minimum visible width persisted that width, after which the file
  explorer never rendered again — the activity-bar Files icon only toggled a visibility flag
  (never restoring the width) and opening a workspace never revealed the sidebar. Now: clicking an
  activity-bar tab while the sidebar is hidden (for either reason) reveals it at its last visible
  width, and every successful workspace open reveals the file explorer (VS Code parity), which
  also heals an already-broken persisted width at the next launch.

- **Installed app no longer crashes at launch when the dev build tree is absent**
  ([#99](https://github.com/PsychQuant/logos/issues/99)). `make bundle` never embedded the
  SwiftPM-generated resource bundles (`SwiftTerm_SwiftTerm.bundle` — the Metal shaders —
  and `Highlightr_Highlightr.bundle`), so `Bundle.module` inside the SwiftTerm fork only ever
  resolved via its compiled-in fallback into this repo's `.build` tree. Cleaning `.build`
  (or running the app on any other machine) made that lookup fail and trap with
  `fatalError` at Metal-renderer adoption, ~4s after launch. The bundle step now copies the
  resource bundles into `Contents/Resources/` and fails loudly if the SwiftTerm bundle is
  missing, making every installed/distributed copy self-contained.

### Added

- **Multi-root `files.exclude` precedence** ([#97](https://github.com/PsychQuant/logos/issues/97)).
  A `.code-workspace` top-level `settings.files.exclude` now applies to every folder, merged with
  each folder's `.vscode/settings.json` `files.exclude` the VS Code way: union of patterns, the
  folder winning per key — so a folder can un-hide a workspace-level exclude by setting it `false`.
  Builds on the per-folder support from the earlier slice.

- **Logos honors `.vscode/settings.json` `files.exclude` in the sidebar**
  ([#97](https://github.com/PsychQuant/logos/issues/97), Slice 1). The `.vscode/settings.json`
  reader seam from #96 (which parsed the file but honored zero keys) now honors its first key:
  a workspace folder's enabled `files.exclude` glob patterns are hidden from the file tree, so
  Logos hides the same entries VS Code hides (e.g. `dist/`, generated output). Only patterns
  whose value is exactly the JSON boolean `true` are applied; a `false`, a conditional
  `{ "when": … }` value, or a non-boolean (e.g. an integer `1`) is left visible. The supported
  glob subset is the common VS Code forms — a `**/`-prefixed pattern (`**/name`, `**/*.ext`)
  matches the leaf name at any depth, while a bare pattern (`name`, `*.ext`) is root-anchored and
  matches only a direct child of the workspace root, exactly as VS Code interprets them (its own
  defaults all carry `**/`). This hard-coded skip list remains a floor `files.exclude` adds to;
  arbitrary path globs and full micromatch are out of scope. The remaining VS Code
  workspace-protocol slices stay tracked in #97.

- **Logos opens VS Code multi-root `.code-workspace` files**
  ([#96](https://github.com/PsychQuant/logos/issues/96)). A workspace is no longer a single
  root folder — it is now an ordered, non-empty set of root folders, aligned with VS Code's
  own workspace definition so the two tools agree on what a "workspace" is. `⌘O` (and
  `--workspace <path>`) accept either a plain directory (→ a one-root workspace, unchanged) or
  a `.code-workspace` file, whose `folders` are resolved relative to the file (absolute paths
  pass through, missing folders are dropped, and a file with zero surviving folders surfaces
  the load-error banner rather than opening empty). The sidebar renders one collapsible section
  per root in file order, and the hosted `claude` session spawns in the workspace's **first
  folder** as its working directory. `.code-workspace` files are read **read-only** (Logos
  never writes them), and a structural `.vscode/settings.json` reader seam is in place that
  currently honors **zero** keys (editor-only concerns stay out of scope). The last-opened
  workspace — folder or `.code-workspace` locator — is restored across launches.

- **Logos now has an app icon.** A vector mark — a warm-amber Greek lambda (λ, for λόγος) with a
  terminal-cursor underscore on a deep charcoal-navy rounded tile, marrying the brand's etymology
  ("word / reason") with its role as a Claude Code terminal host. The source is
  `icon-concepts/logos-icon.svg` (regenerable at any size); the bundled `Resources/AppIcon.icns`
  carries all sizes 16→1024 (+@2x), wired via `CFBundleIconFile` and copied into the bundle by
  `make bundle` / `release-signed`.

- **The status bar is now a claude-hud-style HUD with context + plan usage bars**
  ([#90](https://github.com/PsychQuant/logos/issues/90)). The bottom bar becomes a
  segmented, icon-marked HUD divided by hairline separators. The two plain-text usage
  readouts become green→yellow→red fill bars driven by a shared `HUDProgressBar`
  (green under 70% consumed, yellow 70–90%, red at/above 90%): the **context-window**
  bar reads this window's per-session `WindowUsageModel` (#47/#49) — a fresh session
  reads 0 (#89), so it renders empty, never full — and a new **5-hour plan-usage**
  bar reads the active account's `five_hour` window from the shared `RegistryUsageModel`
  (#51/#52/#53), the same plan budget the 帳號用量 window shows. The plan bar is wired by
  threading the one shared `RegistryUsageModel` into the main window (a new `MainScene`
  parameter + `.environment` injection) and bridging the active account through
  `AccountManager.activeAccountId`; it refreshes event-driven only — on window appear and
  on account switch — coalescing with the usage window's refresh through the shared
  `RefreshCoalescer` (#51), so it never stacks a second keychain dialog. The account
  switcher (⌘K), the cost `+?` sentinel, and the auto-handle state are unchanged.

- **The reorderable account rows now show a drag-handle grip**
  ([#88](https://github.com/PsychQuant/logos/issues/88)). Each drag-reorderable account
  row ([#87](https://github.com/PsychQuant/logos/issues/87)) gains a leading 6-dot grip
  (a compact 2×3 matrix of small `.tertiary` circles) as a visual hint that the row can
  be dragged. The grip is hint-only: the whole row stays press-draggable through the
  List's `.onMove` and the grip itself carries no gesture (`.allowsHitTesting(false)`),
  so a press-drag that starts on the handle still initiates the reorder — single-tap
  select, double-click rename, and the per-row buttons are unchanged. The pinned Main
  row draws no grip (it can't be moved) but reserves the identical leading width so
  every account label stays vertically aligned. `AccountRow` is untouched — the grip is
  a switcher-context wrapper affordance, and it's `.accessibilityHidden` so it stays out
  of VoiceOver.

- **The account switcher pins Main on top and lets you drag to reorder the rest**
  ([#87](https://github.com/PsychQuant/logos/issues/87)). The system-default ("Main")
  account — the one that reuses your Terminal `~/.claude` login — now always renders
  first and cannot be moved; the remaining accounts are drag-reorderable and the new
  order persists to `index.json`, surviving relaunch. The switcher moved from a custom
  `ScrollView + VStack` to a `List` with `.onMove` (the platform's standard reorder
  affordance): a plain click still selects, a press-drag reorders, and double-click
  rename plus the per-row trash / open-in-new-window / pencil buttons are untouched.
  Main is enforced on top by rendering it as a pinned row ABOVE the movable `ForEach`
  (so `.onMove` can never drop anything above it) and by a display accessor that forces
  it first regardless of persisted position. Persistence is a new
  `AccountRegistry.reorder(nonDefaultIDs:)` that runs inside the existing transactional
  `mutate` — a reorder whose save fails rolls the order back intact
  ([#57](https://github.com/PsychQuant/logos/issues/57)), never leaving a half-applied
  order. `AccountRow`'s look is unchanged.

### Security

- **The account reaper re-validates its target as a single safe path component
  before any deletion** ([#80](https://github.com/PsychQuant/logos/issues/80)). The
  guarded delete core (`AccountReaper.reapDirectory`) relied on a resolved-parent
  check (`deletingLastPathComponent().standardizedFileURL == accountsRoot`) plus an
  lstat symlink/dir check. A crafted two-component name of the form `a/../b` defeated
  the parent check — the parent standardizes back to EXACTLY the accounts root, so the
  guard passes — after which `removeItem` resolves the `..` and deletes `<root>/b`, a
  DIFFERENT account's dir than the caller named (empirically confirmed; the plain
  `foo/..` the issue first described is already refused, since its parent standardizes
  to `~/.logos`, not the root). The escape was unreachable in production (both callers
  are gated upstream — `reap` gets `Account.isValidID`-validated ids, `reapOrphans` gets
  `contentsOfDirectory` single-components), but the guard now delivers its documented
  contract independently: it rejects any `<name>` that is not a single safe path
  component (`Account.isValidID` — no `/`, `.`, `..`, or empty) as its FIRST gate, ahead
  of the existing parent-path and symlink guards (defense in depth). Adds
  `LSMultipleInstancesProhibited` to close a related double-launch window: without a
  single-instance lock, a second Logos process mid-`createAccount` could race the first's
  startup GC and have its freshly-created, not-yet-registered dir reaped; Launch Services
  now refuses the second launch, removing the race's precondition.

- **The HUD (and 帳號用量 window) now show per-model weekly usage**
  ([#94](https://github.com/PsychQuant/logos/issues/94)). Claude Code's `/usage` panel shows a
  "Current week (&lt;model&gt;)" bar (e.g. Fable) beyond the 5-hour + all-models-weekly windows; that
  per-model data lives **only** in the endpoint's `limits` array as `weekly_scoped` entries (the flat
  `seven_day_<model>` response fields are null). `UsageClient` now decodes those into their own
  windows (`每週（<model>）`), so both the status-bar HUD and the 帳號用量 window render a bar per
  model the plan scopes — the status bar abbreviates it to the model name. Additive and
  lenient: a response without `limits` (or without scoped entries) is unchanged.

### Removed

- **The standalone `MultiStats` viewer target is retired**
  ([#92](https://github.com/PsychQuant/logos/issues/92)). The in-app 帳號用量 window
  (`AccountUsageWindow`, a SwiftUI `Window` over the same `RegistryUsageModel` /
  `LogosUsage` layer) is its superset — the same per-account plan-usage list, plus
  active-account highlighting, with no separate app to launch — so the redundant
  `MultiStats` product + executable target are removed from `Package.swift`. The shared
  `LogosUsage` / `LogosAccounts` layer is kept (the app + the usage window still use it).
  The retired source is archived, not deleted, under `archive/logos-multistats-target/`.

### Fixed

- **The context bar now shows the model's real window (1M for a 1M-context model), not a flat 200k**
  ([#95](https://github.com/PsychQuant/logos/issues/95)). `ClaudeUsageReader.contextMax` ignored the
  model and returned 200k until *used* tokens crossed 200k, so an Opus 4.8 (1M context) session read
  `0 / 200k`. The transcript's `usage.model` records only the base id (`claude-opus-4-8`, no `[1m]`),
  but Claude Code persists the `[1m]` beta in the account's `settings.json` `model` field — a
  read-only signal Logos already had the config dir for. `contextWindow(sessionModel:selectedModel:
  observedTokens:)` now derives the window from a model→base-window map plus the `[1m]` selection
  (matched by family so a different family's saved default never cross-applies), keeping the
  observed-tokens heuristic only as an upward-correcting fallback. A fresh 1M account reads `0 / 1M`
  up front.

- **The status-bar plan bar now shows *why* it's blank, and surfaces the weekly window too**
  ([#93](https://github.com/PsychQuant/logos/issues/93),
  [#94](https://github.com/PsychQuant/logos/issues/94) quick win). Previously the 5-hour segment
  collapsed every non-loaded state — loading, needs-login, no-credentials, failed — into an
  indistinguishable `5h · —`, so an expired token (Logos reads usage read-only and never refreshes
  tokens by design) looked the same as "still loading". `PlanUsageStatusItem` now renders each state
  distinctly: the HUD bars when loaded, a spinner while loading, and — the actionable one — a
  「⚠ 登入」hint when the account's stored token is expired (re-login in that account's terminal
  restores it), plus 「未登入」/「用量錯誤」for the credential / fetch-failure cases. It also now
  draws the weekly (`seven_day`) window alongside the 5-hour one — `UsageClient` already decoded it,
  the HUD just wasn't showing it. And `LogosUsage`'s usage fetch, previously silent, now logs each
  outcome under subsystem `app.getlogos.logos` (category `account-usage`; account id `.private`), so
  a blank plan segment is diagnosable from `log show`.

- **The per-window usage file watcher no longer leaks / risks a use-after-free when a
  window closes** ([#91](https://github.com/PsychQuant/logos/issues/91)). `FileWatcher`
  registers its FSEventStream with an UNRETAINED pointer to itself, so a running stream on
  a deallocated watcher derefs freed memory on the next event. The only teardown was each
  owner's explicit stop on view disappear (`WindowUsageModel` via `WindowRoot.onDisappear`,
  `PDFLivePreviewModel` via `unbind()`) — a single fragile path: if it didn't fire, the
  stream leaked and could crash. `FileWatcher` now self-cleans with an `isolated deinit`
  (SE-0371, Swift 6.1+) that stops the stream on dealloc, and `WindowUsageModel` gains its
  own `isolated deinit` backstop; both `stop()`s are idempotent, so the existing prompt
  teardown paths are unchanged. This closes the same latent gap for `PDFLivePreviewModel`.

- **A fresh session's status bar shows empty usage instead of the previous session's
  tokens/cost** ([#89](https://github.com/PsychQuant/logos/issues/89)). The usage reader
  resolved a window's transcript by session id, but whenever that id-addressed
  `<sessionId>.jsonl` was not found it fell back to the newest-mtime file under the config
  dir — which, on a fresh session (before claude writes the new session's transcript) or
  during the transient window with no bound session id, is a FOREIGN (previous/other)
  session's transcript. So a just-opened session displayed the prior session's token count
  and cost. `ClaudeUsageReader.transcriptURL` now binds only to the exact `<sessionId>.jsonl`
  and returns `nil` when there is no bound session id or its transcript does not exist yet;
  the status bar then shows empty/zero rather than another session's numbers (the
  reset-on-switch of [#47](https://github.com/PsychQuant/logos/issues/47) held by the
  retain-last-good guard of [#83](https://github.com/PsychQuant/logos/issues/83)). The
  newest-mtime `activeTranscriptURL` heuristic — the pre-[#49](https://github.com/PsychQuant/logos/issues/49)
  MVP fallback and the root of the staleness — is removed. The rare
  caller-supplied-own-`--session-id` case now shows empty rather than a best-effort
  newest-mtime read; empty is strictly better than a stale foreign session's figures.

- **The account switcher's "Add account" and "Add system account" buttons no longer
  collide** ([#86](https://github.com/PsychQuant/logos/issues/86)). Both live in the
  sheet's `VStack(spacing: 0)`, but "Add account" set only `.padding(.top)` and "Add
  system account" only `.padding(.bottom)`, so the gap between them was zero and they
  sat flush. The system-account button now uses symmetric `.padding(.vertical, 8)`.

- **The activity bar's gear opens Settings and the dead account icon is gone**
  ([#85](https://github.com/PsychQuant/logos/issues/85)). The bottom two icons
  were dead placeholders: clicking the gear or the person just `select()`ed a tab
  whose sidebar panel only renders real content for `.files`. The gear is now a
  standalone action button that opens the Settings window via
  `@Environment(\.openSettings)` (same target as Cmd+, / the `Settings` scene) and
  never marks itself active. The account icon is removed entirely — the status-bar
  account item remains the single account entry. `ActivityBarSelection.Tab` now
  models only browsable sidebar panels (`files`, `search`, `sessions`); `.settings`
  and `.account` are dropped, and `ActivityBarIcon` is presentation-only so the
  gear reuses it as a non-selecting action.

- **The status-bar usage reader now logs a real transcript I/O error instead of
  swallowing it silently** ([#83](https://github.com/PsychQuant/logos/issues/83)).
  `WindowUsageModel.defaultRead` read the session transcript with
  `try? String(contentsOf:)`, collapsing three outcomes into one silent `nil`: the
  transcript not being written yet (benign, the common case on every fresh window),
  a genuine I/O fault (permission denied, disk error), and any other read failure.
  So a real permission/disk error made the status-bar usage stop updating with no
  `log show` trail — unlike `AccountReaper`, which logs every guard-refusal and catch.
  The read is now a `do/catch`: a `CocoaError.fileReadNoSuchFile` (transcript absent)
  stays silent, and any OTHER error is logged at `.error` via an
  `os.Logger(subsystem: "app.getlogos.logos", category: "window-usage")`. The
  interpolated error is marked `privacy: .private` because the transcript path can
  carry an account identifier (#22 / #34). The return contract is unchanged — every
  failure still returns `nil`, so the caller retains last-known-good rather than
  zeroing live usage; a new `WindowUsageModelTests` case pins that retain-last-good
  invariant against a future `snapshot?.contextTokens ?? 0`-style regression.
- **The login-URL reassembler now ends the URL at a bare newline instead of
  splicing the next line onto the query** ([#82](https://github.com/PsychQuant/logos/issues/82)).
  `OAuthURLDetector.reassembleURL` stopped only at a structural blank line (two
  line feeds), treating any single `\n` as wrap-continuation. So URL-valid content
  on the line immediately after the authorize URL — separated by a single `\n`, not
  a blank line — was spliced onto the query string with the newline dropped and no
  delimiter (e.g. `…authorize?code=true&state=x` + `\n` + `token=SECRET123` → `…state=xtoken=SECRET123`).
  Harmless with today's claude output (URL → blank line → prompt) but fragile if a
  future claude reformats its output or another source interleaves into the PTY
  before the blank line. The fix leans on the terminal's own wrap shape: its
  `\r\r\n` hard-wrap iterates (Swift clusters CR+LF into one `Character`) as a lone
  `\r` then the `\r\n` grapheme, so a genuine wrap's line feed is ALWAYS immediately
  preceded by a lone `\r`, whereas a bare `\n` break is not. The reassembler now
  treats a line feed as continuation only when it is that CR-padded wrap and ends
  the URL at a bare `\n` (keeping the blank-line boundary as a fallback). The
  host/path lock is untouched — only where the URL ENDS changed, not what host or
  path is accepted.
- **Closing the Account Usage window now cancels its in-flight usage fetches**
  ([#81](https://github.com/PsychQuant/logos/issues/81)). `AccountsModel.refreshAll`
  and `RegistryUsageModel.refreshAll` coalesce concurrent passes onto one shared
  `Task` so overlapping callers can't each start a serialized first pass and re-stack
  the per-account Keychain authorization dialogs (#51). But an unstructured `Task`
  does not inherit its creator's cancellation, and `URLSession.data(for:delegate:)`
  auto-cancels its transfer only when ITS calling Task is cancelled — so the coalescing
  wrapper severed that link, and closing the usage window (its SwiftUI `.task`
  cancelled) left the in-flight usage fetches running to completion in the background.
  No wrong state, just wasted network and CPU nobody was waiting on. A new
  `RefreshCoalescer` reference-counts the observers awaiting the shared pass and cancels
  it only once the LAST one goes away — so the #51 coalescing guarantee (one pass under
  N concurrent callers, one dialog sequence) is preserved while one caller leaving never
  tears the pass out from under the others, and a fully-abandoned pass stops promptly. A
  first pass that is cancelled before finishing does not mark first-pass-complete, so the
  next refresh re-serializes rather than fanning out and re-stacking dialogs.
- **The native login-URL open now fires for the Anthropic Console form too**
  ([#35](https://github.com/PsychQuant/logos/issues/35)). Installed claude ships TWO
  authorize forms in one OAuth-config struct — `https://claude.com/cai/oauth/authorize`
  (Claude.ai / subscription) and `https://platform.claude.com/oauth/authorize`
  (Anthropic Console / API) — but `OAuthURLDetector` was hardcoded to the first, so a
  Console login never triggered the native open. The user was left to hand-copy the
  ~400-char CRLF-wrapped URL and truncated the tail carrying `redirect_uri`, which claude
  rejects ("Missing redirect_uri parameter"). The detector now models an allowlist of
  per-form `(startToken, host, path)` triples and validates each reassembled candidate
  against ITS OWN host + path — exactly two enumerated, fully-qualified pairs, no wildcard
  or host-suffix match, so the #17 "never open an arbitrary URL" invariant is unchanged.
  Re-adds `OAuthURLDetectorTests` (dropped in #34) with realistic `redirect_uri`-carrying
  fixtures for both forms, including the CRLF-wrap reassembly regression. Interim fix
  (authorize forms drift across claude versions); the proper retirement folds this into a
  first-class `claude auth login` button (tracked separately).

- **Hosted unit tests no longer launch the full production app** and its side-effects
  ([#78](https://github.com/PsychQuant/logos/issues/78)). `LogosHostedTests` is app-hosted
  (`TEST_HOST = Logos.app`), so every hosted-test run brought up the entire production UI,
  which asynchronously spawned the real `--dangerously-skip-permissions` claude subprocess
  AND engaged the GPU Metal renderer ~2s in. Whichever bystander test was executing then
  (`RendererAdoptionTests`) was charged with the "unexpected exit," producing the confusing
  `** TEST FAILED **` aggregate with every suite green — and, worse, a live privileged
  subprocess ran inside `xcodebuild test` on every launch. A new
  `HostedTestEnvironment.isHostedUnitTesting` probe (keyed off `XCTestConfigurationFilePath`,
  which the app-hosted unit-test host carries but the separately-launched XCUITest app does
  not) now gates the spawn (`SwiftTermView.Coordinator.startIfNeeded` returns early) and the
  real Metal engagement (`enableMetalIfAvailableOnce` short-circuits). The probe is
  env-injectable and the Metal flag is set only at the production `makeNSView` seam, so a
  directly-constructed test view (`RendererAdoptionTests`) still exercises the adoption path
  and the XCUITest terminal still renders + spawns. `swift test` stays green; the Track-B
  confirmation that the crash no longer fires is deferred to a signed hosted run.

### Added

- **VoiceOver can now select and rename an account from the switcher**
  ([#77](https://github.com/PsychQuant/logos/issues/77)). The row's select/rename were
  pointer-only `.onTapGesture`s, which — unlike a `Button` — expose no accessibility
  activation, so VoiceOver could read a row but not switch to or rename it. The
  account-label `Text` now carries `.accessibilityAddTraits(.isButton)` plus an
  activate action (`.accessibilityAction { onSelect() }` = switch account) and a
  "Rename" custom action (`.accessibilityAction(named:)`, in the actions rotor),
  composing with the existing active-state `.accessibilityValue` (#72). The trait is
  attached to the label LEAF, never the row HStack — combining the container would
  flatten the trash / open-in-new-window / pencil buttons, regressing independent
  VoiceOver access and breaking the label-based UI tests (#79). Pointer select
  (single-tap) and rename (hardware double-click) are unchanged. `.isButton` promotes
  the label's XCUIElementType from `.staticText` to `.button`, so the Track-B UI tests
  now query the account label via `buttons[label]`.

- **The status bar shows a real session cost instead of a `$0.00` placeholder**
  ([#48](https://github.com/PsychQuant/logos/issues/48)). The cost item read a hardcoded
  placeholder on `StatusBarViewModel`; it now derives a real figure from the same session
  transcript the token/context item uses (#47/#49). `ClaudeUsageReader` accumulates
  input / output / cache-creation / cache-read tokens per model across EVERY assistant turn
  (cost sums the whole session, unlike the context read which is only the latest turn), then
  applies a per-model-family price table where cache-write and cache-read carry DISTINCT
  multipliers (never the input rate, never summed). `WindowUsageModel` computes it on each
  refresh — off the main actor, one FS read shared with the context parse — and
  `CostStatusItem` now reads `WindowUsageModel` (the old `StatusBarViewModel.sessionCost*`
  is left dead-but-compiling, mirroring the #47 token migration). A model with no price
  entry (a novel/preview id, or a record with no model id) is never silently priced at $0
  or the input rate — its tokens raise a sentinel that appends a visible "+?" to the figure,
  marking it a lower bound. Read-only over claude's transcript; never touches credentials
  (#34), and the cost resets on every account switch (the #47 reset-on-switch contract,
  extended to cost).
  - **Cost semantic — pending user confirmation at verify.** The figure is a *notional
    API-equivalent* (ccusage parity): what this session's tokens would cost on the metered
    pay-per-use API, which is NOT necessarily the user's actual subscription bill. This is
    shipped as the default with an explanatory tooltip; the price-table rates are the
    published Anthropic list prices by model family and are flagged for confirmation.

- **Per-account config dirs are created at `0o700`**
  ([#63](https://github.com/PsychQuant/logos/issues/63)). `AccountManager`'s default
  directory creator made each account's `~/.logos/accounts/<id>/.claude` chain at the
  process umask default (typically `0o755`, world-traversable) with no `attributes:`.
  It now creates them `0o700` and, best-effort, re-`chmod`s the `.claude` leaf and its
  `<id>` intermediate to `0o700` after — so a dir left at `0o755` by an earlier build
  converges on the next create/switch (create-time attributes are a no-op on an
  existing dir). Defense-in-depth atop #61's accounts-root `0o700` (already the
  load-bearing block on other-user traversal), not a reachable gap; the closure was
  also extracted to a testable `defaultEnsureDirectory` so the production default is
  now covered. No user-visible behavior change.

- **Removing an account now deletes its data dir, and stale account dirs are
  swept at startup** ([#50](https://github.com/PsychQuant/logos/issues/50)). Every
  `remove()` rewrote `index.json` but never deleted the account's
  `~/.logos/accounts/<id>/` dir, so each removed account orphaned its directory
  forever (50+ observed in practice). A new `AccountReaper` now reaps the removed
  account's dir — but ONLY after the registry persist durably succeeds (a
  persist-failed, #57-rolled-back remove deletes nothing) and NEVER for a
  system-default account (it reuses the shared `~/.claude`, which is never
  touched). To clear the historical orphans, `AccountManager.reapOrphanedDirectories()`
  runs a conservative one-shot GC at launch, BEFORE any claude spawn (so it can't
  race a live session writing its config dir): a `<id>/` is reaped only when it is
  BOTH absent from the registry AND carries no claude config JSON — the same
  "never a real account" signal `AccountDiscovery` filters on — so a registered or
  logged-in dir is always spared. Because deleting account data is irreversible,
  every removal is doubly guarded: the resolved path must sit directly under the
  accounts root and must not be a symlink. Production only — the `--ui-testing`
  path uses a per-launch temp registry and is skipped, so a real orphan is never
  swept during a UI test.

- **The account-row's icon-only controls and active state are now announced to
  VoiceOver** ([#72](https://github.com/PsychQuant/logos/issues/72)). The trash and
  open-in-new-window buttons were icon-only with no VoiceOver label (their `.help()`
  tooltips are hover-only, not spoken) — they now read "Delete account" and "Open in
  new window". The active-account state, previously conveyed only by a filled circle,
  is carried as an accessibility value on the row's name ("work, active"); the circle
  itself is marked decorative so it isn't announced twice. The state is exposed as a
  *value* rather than a relabeled/combined element specifically so the row's name
  stays independently queryable — the account-switch and rename UI tests select rows
  by that name. Purely semantic: no pixels change (the six view-snapshot baselines are
  byte-identical).

- **The announce-at-setter discipline is now guarded, and the announcer is testable**
  ([#75](https://github.com/PsychQuant/logos/issues/75)). The #71 round-2 rule — every
  user-facing error caption is set through a helper that posts a VoiceOver announcement
  — was previously enforced only by a comment. A source-scan test now fails the plain
  `swift test` suite if any of the four error slots is assigned a non-nil value outside
  its setter, or if a setter loses its announcement call; and the announcer is an
  injectable closure (production default unchanged), letting a hosted test assert the
  post actually fires — including the identical-retry case that motivated the round-2
  redesign. Test/seam only; no user-visible behavior change.

- **The switcher's error captions are announced to VoiceOver**
  ([#71](https://github.com/PsychQuant/logos/issues/71)). Every error setter now posts
  an `AccessibilityNotification.Announcement` imperatively at the mutation site — a
  failed delete/rename/add is no longer visually-only feedback, **including a retry
  that fails with the identical message** (view-lifecycle hooks structurally miss that
  case: the same-string re-set coalesces to a no-op render, caught by the verify
  ensemble in round 1). The add-account form's error also joins the unified affordance
  (queryable id `logos.account.add.error`, consistent styling, announced), replacing
  its bespoke unlabeled text; a new hosted snapshot pins the form-with-error layout.
  Note: whether VoiceOver audibly speaks the announcement end-to-end still needs a
  manual spot-check — CI cannot assert audio.

### Changed

- **Ratified the label-query convention for `AccountRow` controls**
  ([#79](https://github.com/PsychQuant/logos/issues/79)). The row HStack's
  `.accessibilityIdentifier("logos.account.row")` propagates onto every child a11y
  element, shadowing each control's own identifier at runtime — so `app.buttons["logos.account.delete"]`
  never resolves under XCUITest. Rather than relocate the row id onto a non-propagating
  leaf (an accessibility-tree restructure for marginal benefit), the shadowed child ids
  are kept purely as intent markers and every row control is queried by its VoiceOver
  LABEL. Formalized in the in-code NOTE on `AccountRow.swift` and the CLAUDE.md testing
  convention; no runtime or user-facing change (VoiceOver output was already correct).

- **The status-bar usage parse now runs off the main actor with a newest-wins stale
  guard** ([#49](https://github.com/PsychQuant/logos/issues/49)). `WindowUsageModel.refresh()`
  previously enumerated the account's `projects/` tree, read the full transcript, and
  parsed it per-line synchronously on the main actor on every FileWatcher fire — a
  growing session transcript can make that a visible hitch. The read + parse now hop off
  the main actor (mirroring `AccountUsageModel`), and only the small parsed snapshot
  crosses back to be applied. Because two reads can now resolve out of order (a slow read
  for account A racing a switch to B), each refresh claims a monotonic generation and
  applies its result only while it is still the newest AND the live `configDir` still
  matches the one it read — so a stale read can never clobber a just-switched account
  (preserves the #47 reset-on-switch contract). Read-only over claude's transcript;
  never touches credentials (#34). No user-visible behavior change beyond a smoother
  status bar.

- **The status bar now binds to the exact claude session it spawned instead of guessing
  newest-mtime** ([#49](https://github.com/PsychQuant/logos/issues/49)). Previously the
  usage reader picked the most-recently-modified `.jsonl` under the account's `projects/`
  tree — a heuristic that reads the wrong session's usage when two windows share one
  config dir, or briefly during a switch. The terminal now spawns claude with a fresh
  `--session-id <uuid>` (a lowercased `UUID` minted once per real spawn at the
  `hasStarted`-gated Coordinator seam — claude hard-errors on a reused id, so it must be
  per-spawn, not on the render-recreated `ClaudeProcessConfig`), reports that id back to
  `WindowUsageModel` via an `onSessionSpawned` callback, and the reader resolves
  `<configDir>/projects/**/<uuid>.jsonl` directly. Newest-mtime stays as the fallback for
  the window before claude's first write and for any session started without an id (a
  caller-supplied `--session-id` is respected and not double-bound). The bound id is
  cleared on every account switch so a stale id never targets the previous account's
  transcript. Still read-only over claude's transcript; never touches credentials (#34),
  and preserves the #47 reset-on-switch contract.

- **Concurrent usage refreshes no longer restack the first-run Keychain
  authorization dialogs** ([#51](https://github.com/PsychQuant/logos/issues/51)). The
  first refresh pass already serialized its per-account Keychain reads so the macOS
  authorization dialogs would not stack — but that guarantee held only *within* one
  pass. Two `refreshAll()` calls overlapping on the first pass (e.g. window-open racing
  an initial auto-refresh) each read `hasCompletedFirstPass == false` and started their
  own serialized loop, so the two loops interleaved and the dialogs stacked again.
  `refreshAll()` on both `AccountsModel` and `RegistryUsageModel` now coalesces onto a
  single in-flight pass: a concurrent caller awaits the running pass instead of
  launching a second. The guard is a synchronous check-and-set with no suspension in
  between, so on the serial main actor it is atomic without a lock; later passes still
  regain concurrency once the first has completed. Session-volatile, unchanged.

- **The usage refresh path is hardened against stale-response ordering and a
  redirect token leak** ([#53](https://github.com/PsychQuant/logos/issues/53)). Two
  defense-in-depth gaps on the read-only usage fetch. (1) `AccountUsageModel.refresh()`
  crossed two `await` points before assigning any terminal state, so two overlapping
  refreshes on one row could resolve out of order and let a slow, older response
  overwrite a newer one; a per-instance generation token now gates every terminal
  assignment so the newest refresh always wins. (2) The token-bearing request followed
  redirects with URLSession's defaults; a per-task delegate now strips the
  `Authorization` header on any cross-host redirect (same-host hops are unaffected), so
  the OAuth bearer can never cross to another origin. Foundation-only — no new Security
  surface.

- **A type-drifted field in one usage window no longer blanks the whole panel**
  ([#52](https://github.com/PsychQuant/logos/issues/52)). `UsageClient.parse` decoded the
  response atomically, so a single unexpected field type inside one window (`five_hour`
  or `seven_day`) threw the entire decode, collapsed to `.malformed`, and rendered the
  account as failed — taking the sibling window's still-valid utilization down with it.
  Each window now decodes leniently: a drifted window drops out on its own while its
  sibling stays, and within a window `utilization` is the only load-bearing field (a
  drifted `resets_at` yields a nil reset date, not a lost window). A well-formed body
  whose windows are all drifted is a valid-but-empty parse; only a non-object body stays
  `.malformed`. The unused `limitDollars`/`remainingDollars` fields — decoded and stored
  but never read by any view — were dropped in the same pass.

- **Snapshot baselines compare with a perceptual tolerance instead of raw bytes**
  ([#73](https://github.com/PsychQuant/logos/issues/73)). A macOS point update's
  sub-visual anti-aliasing/font drift byte-broke 4 of the 6 committed baselines with
  zero visible difference. The single `snapshot()` funnel now asserts at
  `precision: 0.98, perceptualPrecision: 0.98` (CIELAB ΔE threshold 2 — just above the
  ~1 just-noticeable-difference), and the 4 drifted baselines were re-recorded. Real
  layout/color regressions still RED (verified with a deliberate perturbation), with
  one honestly-documented floor: a comma-level edit in one text line of a large canvas
  can fit inside the 2% pixel budget (verify-DA finding — recorded in CLAUDE.md and the
  suite doc rather than papered over). The `cancelRename` caption-exception from the
  #74 review is likewise now pinned by a source-scan guard test instead of comment-only.

- **Account labels are now bounded by UTF-8 byte size, not just character count**
  ([#62](https://github.com/PsychQuant/logos/issues/62)). Every label length gate
  measured Swift `Character` (grapheme-cluster) count, which does not bound persisted
  size — one cluster can carry an unbounded number of combining scalars (a "zalgo" base
  plus thousands of combining marks, or a long ZWJ emoji sequence), so a 30-character
  label could smuggle hundreds of KB into the accounts index. Because the index has a
  whole-file size cap that empties the entire registry when exceeded (#61), an unbounded
  label was a silent data-loss vector on next launch, not just bloat. A single shared
  normalizer now enforces a **256 UTF-8 byte** cap alongside the existing 30-character
  cap and unifies the trim set on `.whitespacesAndNewlines`. **User-visible:** a label
  that was previously accepted or persisted while over 256 bytes (but within 30
  characters) is now **rejected** on create/rename, and **silently clamped** — always on
  a whole-character boundary, never mid-character — when repaired on load. 256 bytes
  comfortably fits any realistic label (30 CJK characters ~= 90 bytes, 30 flag emoji =
  240 bytes) while blocking the attack. **Round-2 hardening** (verify ensemble, three
  reviewers converging): the load-repair uniquify sweep now reserves byte budget for its
  `" (recovered)"` disambiguation suffix *before* clamping — previously two identical
  at-cap labels could have the suffix clamped away entirely, letting duplicates survive
  invisibly (the bookkeeping tracked pre-clamp candidates and the no-op diff never
  persisted a fix). Uniqueness now operates on the realized stored label, and the
  boundary cases (250/255/256-byte bases, single 256-byte cluster duplicates,
  second-load convergence) are pinned by tests.

- **Live-preview error surfaces no longer show raw error dumps, and a failed "Add
  system account" now gives feedback** ([#74](https://github.com/PsychQuant/logos/issues/74)).
  Sibling instances of the #70 pattern outside that cluster: the PDF live-preview
  build banner and the Live-Preview settings read/save captions interpolated the raw
  Swift error (`"\(error)"`) into user-facing text — reachable with process-launch / IO
  errors whose descriptions can embed filesystem paths. They now show a friendly
  sentence ("Couldn't run the build command." / "Couldn't read the config file." /
  "Couldn't save the config file.") and log the underlying error to the unified log at
  explicitly-`private` privacy (`Log.workspace` / `Log.settings`). Separately, the
  switcher's "Add system account" button used to silently discard a registry-persist
  failure — it now surfaces "Couldn't add the system account — the change didn't save.
  Try again." through the same announced error affordance as delete/rename/add
  (queryable id `logos.account.addSystemDefault.error`).

- **The switcher's fallback error captions no longer show raw error dumps**
  ([#70](https://github.com/PsychQuant/logos/issues/70)). The add-account and rename
  catch-alls interpolated the raw Swift error into the caption — reachable with
  FileManager/registry-persist errors whose descriptions can embed filesystem paths.
  They now show a friendly sentence ("Couldn't create/rename the account — the change
  didn't save. Try again.") and log the underlying error to the unified log
  (`Log.account`, default privacy — paths stay redacted). Known validation messages
  are unchanged.

- **The delete-failure caption is now English, like every other message in the switcher**
  ([#69](https://github.com/PsychQuant/logos/issues/69)). The #60 caption shipped in Chinese
  ("無法移除帳號——變更未能儲存，請再試一次。") while all sibling strings are English — the
  sheet's only mixed-language surface. It now reads "Couldn't remove the account — the
  change didn't save. Try again." (snapshot baseline re-recorded to pin the new text).
  Proper localization (String Catalog + `LocalizedStringResource`-typed error pipeline)
  stays recorded debt on #69 until i18n actually lands.

- **Default theme is now Dark** ([#46](https://github.com/PsychQuant/logos/issues/46)).
  Logos hosts a fixed-dark terminal, so a light chrome over a dark terminal read as a
  jarring split. The out-of-box default `GeneralSettings.theme` moves `.system` → `.dark`
  (like iTerm / Warp / Ghostty, which are dark-first). The Theme setting (System / Light /
  Dark) is unchanged — a saved override always wins, only the default changed.

### Added

- **"Main" account reuses your existing system `~/.claude` login** ([#54](https://github.com/PsychQuant/logos/issues/54)).
  Every Logos account is normally isolated in its own `CLAUDE_CONFIG_DIR`, so it is separate
  from the login you already have when you run `claude` in a terminal. The account switcher now
  has an **"Add system account"** action registering a single system-default "Main" account
  (badged "system") that spawns claude with **no** `CLAUDE_CONFIG_DIR` override — it falls
  through to the system `~/.claude` + its keychain entry, reusing that login with **zero
  credential touch** (Logos reads no token; it just declines to isolate this one account,
  honoring the #34 red line — not the #12-removed capture path). `HOME` is never overridden
  (#21); the spawn strips any inherited config-dir vars so it truly falls through to `~/.claude`.
  Opt-in MVP; usage-window integration ([#55](https://github.com/PsychQuant/logos/issues/55)) is a
  follow-up. The system-default is now **hardened** ([#56](https://github.com/PsychQuant/logos/issues/56)):
  it has a stable **fixed id** (not the mutable label), so a "Main" system-default coexists with an
  isolated "Main" in either creation order; a **load-time invariant** self-heals a corrupt index to a
  single system-default (migrating a legacy UUID id to the fixed id, non-destructively demoting any
  extras, and re-pointing the active selection); and the add action returns a result
  (`.added` / `.alreadyExists` / `.failed`) instead of silently no-oping. Hardening surfaced via a
  6-AI ensemble review (two rounds); the second round also surfaced deeper `AccountRegistry`
  invariant gaps (global id-uniqueness, transactional persist semantics) reachable only via
  crafted/corrupted persisted data — tracked separately in
  [#57](https://github.com/PsychQuant/logos/issues/57).

- **Account registry enforces global invariants with transactional persists** ([#57](https://github.com/PsychQuant/logos/issues/57)).
  The #56 follow-up: `AccountRegistry` now guarantees — at mutation time AND against
  crafted/corrupted persisted data at load time — that no two accounts share an id, the
  reserved fixed id belongs to the system-default alone, and at most one system-default
  exists. Every user mutation (add / rename / remove) runs through a transactional
  `mutate` primitive: a failed disk persist rolls the in-memory list back, so memory
  never diverges from disk. The round-1 6-AI verify hardened three more edges:
  `remove()` now **throws** on a failed persist (and `AccountManager.remove()` returns
  `Bool`, updating the active selection / live-401 flag only when the removal really
  happened — no more desync against a rolled-back registry); the load-time `normalize()`
  gained an unconditional global id-uniqueness sweep (steady-state reserved-id squatters,
  duplicate ids with zero system-defaults, and multiple reserved-id occupants are all
  repaired — previously each survived a specific corruption shape); and a legacy-migration
  save failure now folds into `normalizeDidPersist` via `normalize(forceSave:)`, so the
  flag reports the true on-disk state and the healed active id is never persisted against
  a phantom index. The round-2 6-AI verify (first with a completed cross-model Codex leg)
  hardened four more edges in-scope: `add()` now gates **reserved-id ownership** at
  mutation time (an isolated account may not take the fixed id, a system-default may not
  take any other — previously only the next launch's `normalize()` repaired this);
  `mutate`'s rollback now also covers a throwing mutation body, not just a failed save;
  normalize's fresh-id generation is collision-proof against every current id (not just
  already-visited ones); and removing a nonexistent id is a true no-op that never touches
  the disk. Residual (non-blocking) findings were filed as follow-ups:
  [#58](https://github.com/PsychQuant/logos/issues/58) (heal a resolvable-but-wrong active
  id after normalize reassigns ids), [#59](https://github.com/PsychQuant/logos/issues/59)
  (load-time label invariants), [#60](https://github.com/PsychQuant/logos/issues/60)
  (surface remove failure in the switcher UI), and
  [#61](https://github.com/PsychQuant/logos/issues/61) (crafted-index defense-in-depth).

- **Active selection heals when a corruption repair reassigns its id** ([#58](https://github.com/PsychQuant/logos/issues/58)).
  `normalize()`'s id-uniqueness repair (#57) can take an id away from one account and
  leave it resolving to another — a stored active selection pointing at such an id
  used to rebind **silently** to the wrong logical account (the heal only fired for
  unresolvable ids), permanently, with `active` seeding new windows'
  `CLAUDE_CONFIG_DIR`. The registry now records the ownership-ambiguous ids of each
  load-time repair (`reassignedIDs`, same pattern as `normalizeDidPersist`), and
  `AccountManager` heals a stored active id that appears in the set exactly like a
  dangling one (system-default first, persist gated on the repair having landed).
  Surfaced by the #57 round-2 Devil's Advocate via an empirical probe.

- **Labels from a crafted index are repaired at load** ([#59](https://github.com/PsychQuant/logos/issues/59)).
  Persisted labels bypass the mutation-path validation (decode doesn't trim), so a
  crafted/corrupted `index.json` could carry empty, whitespace-padded, over-long, or
  duplicate isolated labels straight into the switcher UI. `normalize()` gains a
  phase-3 label pass: trim, `(unnamed)` placeholder for empties, 30-char clamp, and
  `(recovered)`-suffix uniquification for duplicate isolated labels (first occurrence
  keeps; the system-default stays exempt so a system-default "Main" still coexists
  with an isolated "Main"). Idempotent — a clean index is never rewritten.

- **Crafted-index defense-in-depth: id format validation, decode caps, restrictive
  permissions** ([#61](https://github.com/PsychQuant/logos/issues/61)). An account id
  is a path component (`~/.logos/accounts/<id>/.claude` → the spawned claude's
  `CLAUDE_CONFIG_DIR`), yet a crafted `index.json` could carry a traversal id like
  `../../…` straight into that path. Ids are now format-checked (ASCII
  letters/digits/hyphen, 1–64 chars) at the `add()` gate AND repaired (fresh UUID) by
  a new `normalize()` phase 0 at load. The attacker-writable index also gains decode
  caps (1 MB / 500 accounts — beyond either it loads like a corrupt file: empty, bytes
  preserved as evidence), and persistence applies restrictive modes — accounts root
  `0o700` and index `0o600`, both re-applied after every atomic write (best-effort). A
  `0o700` accounts root blocks other-user traversal into every per-account config dir
  beneath it, so it converges regardless of which module created the directory chain
  first (the round-1 verify caught that a create-time attribute alone was a no-op when
  a sibling module built the chain first).

- **The account switcher surfaces a failed delete instead of a silent no-op**
  ([#60](https://github.com/PsychQuant/logos/issues/60)). `AccountSwitcherSheet.delete()`
  was written before #57 made `AccountManager.remove()` return a `Bool` (a failed
  registry persist rolls back and the account stays alive). The handler still (1)
  discarded that `Bool` — a failed delete looked like the tap did nothing — and (2)
  cleared the row's inline-edit state **before and regardless of** the result, so a
  rolled-back remove silently left edit mode as if the account were gone. It now
  branches on the `Bool`: on failure it shows a red caption ("無法移除帳號——變更未能
  儲存，請再試一次。", queryable id `logos.account.delete.error`) and preserves edit
  state; only a real removal tears the edit state down. The rename- and delete-error
  captions are unified into one presentational `SheetErrorLine`, mutually exclusive
  (each user action clears the other's stale error). A hosted snapshot pins the new
  caption's rendering; the end-to-end failed-remove flow needs a persist-failure UI
  seam the `--ui-testing` harness lacks and stays a documented Track-B gap.

- **The "Main" (system-default) account is now integrated into the usage-tracking layer**
  ([#55](https://github.com/PsychQuant/logos/issues/55)). The #54 Main account reuses the
  system `~/.claude` and never materializes a per-account config dir, but the usage layer
  keyed everything off `configDirPath` (`~/.logos/accounts/system-default/.claude`), so
  Main showed a broken/empty row everywhere. A new `Account.usageConfigDir` resolves each
  account's REAL claude config dir (`~/.claude` for the system-default, `configDirPath`
  otherwise), and both usage surfaces now use it: the dedicated usage window
  (`RegistryUsageModel`) builds Main's row with the bare `Claude Code-credentials` keychain
  so it shows real plan usage under the "Main" label, and a Main-bound window's status bar
  (`WindowUsageModel`) reads the `~/.claude` session transcript. The dedicated window also
  highlights the launcher's active/seed selection ("使用中" badge), and the standalone
  MultiStats viewer labels the discovered `~/.claude` row "Main" instead of a derived name.

- **Status bar shows real token / context-window usage** ([#47](https://github.com/PsychQuant/logos/issues/47)).
  The `<used> / <max>` token item was a static placeholder (`0/200k`). It now reads the real
  usage from the window's account session transcript JSONL (`message.usage` — input + cache
  read/creation) via a pure `ClaudeUsageReader`, file-watched for live updates, and is
  **per-window** (each window shows its own account's session, mirroring #42). The context-window
  max is data-driven (jumps to 1M once a session provably exceeds 200k). Switching a window's
  account clears the reading immediately (no lingering on the prior account), and the file
  watcher is torn down when the window closes. **Cost** stays a placeholder — the transcript
  has no cost field, so it must be derived; deferred to
  [#48](https://github.com/PsychQuant/logos/issues/48). Background-parse + a reliable
  session→transcript binding are tracked in [#49](https://github.com/PsychQuant/logos/issues/49).

- **Per-window account binding — open a window per account, run them in parallel** ([#42](https://github.com/PsychQuant/logos/issues/42)).
  The main scene is now a **value-based `WindowGroup(for:)`**: each window carries its
  own account via a per-window `WindowAccountSelection`, instead of all windows sharing
  one global active account. `File ▸ New Window for Account ▸ <account>` (and a per-row
  "open in new window" affordance in the account switcher) opens a window bound to a
  chosen account through `openWindow(value:)`; the terminal pane spawns claude with that
  window's account, so three accounts can run in three windows at once — each with its
  own `CLAUDE_CONFIG_DIR`. Distinct accounts are fully isolated and non-interfering (two
  windows on the *same* account share that account's session-volatile live-401 state —
  see #44). This is **additive**: the
  in-window switcher still works and is **window-local** (switching in one window never
  changes another, nor the new-window default). The isolation layer
  (`ClaudeConfigEnvironment.apply`) is unchanged — a state-scoping change, not an
  isolation change — and the live-401 re-auth path is now scoped to the pane's own
  account. `AccountManager.activeAccountId` is repositioned as the *seed for new windows*
  + the Settings→Accounts highlight (the Settings switcher stays global, preserving the
  #20 contract). Implemented as a pure, unit-tested `WindowAccountResolver` (seed/resolve
  with graceful degrade for deleted accounts) plus the SwiftUI wiring. Window-account
  restoration across relaunch is opted into via `ApplicationSupportsSecureRestorableState`
  in `Info.plist` (#43) — whether SwiftUI actually restores the value-based windows still
  depends on the macOS "Close windows when quitting" setting + a manual relaunch check.

- **`LogoSwitch` module — first-party-safe claude multi-account switching + auth** ([#34](https://github.com/PsychQuant/logos/issues/34), in progress).
  Began extracting the account/auth surface (#12 isolation, #33 login-shell env,
  #31 forced-reauth) into a repo-local, UI-free SwiftPM library `LogoSwitch` that
  acts strictly as a **launcher**: it sets per-account `CLAUDE_CONFIG_DIR`, spawns
  claude, and invokes claude's own `auth login/logout/status` — it never reads,
  copies, or overwrites an OAuth token (the deliberate opposite of
  better-agent-terminal's credential-swap switch, which `security
  find-/add-generic-password`s claude's keychain entry on every switch). The
  target links Foundation + os only and does **not** import `Security`, so a
  keychain call is a compile error; a new `RedLineAuditTests` guard scans the
  module's sources (comments stripped) for `import Security` / `SecItem` /
  `find-/add-generic-password` / `/usr/bin/security` and fails the build on any
  hit. The staged migration is in progress: the target scaffold + red-line guard
  are in place, and `LoginShellEnvironment` (#33, with the module's own
  `os.Logger` and the now-`Sendable` `Process` watchdog de-`nonisolated(unsafe)`-ed)
  the `Account` value model (with its #21 `id`/`HOME` doc-rot corrected), and
  `ClaudeProcessConfig` — whose per-account env layering is extracted into a pure,
  directly-tested `ClaudeConfigEnvironment.apply(base:configDir:)` (the #12/#21
  isolation primitive) — are migrated into the module, as is `ClaudeBinaryResolver`
  (the claude-binary discovery half extracted from `TerminalConfig`; the appearance
  config + `--ui-testing`/`--claude-path` launch-arg seams stay in the app). The
  passive detectors (`OAuthURLDetector`/`LoginPromptDetector`/`RollingTerminalBuffer`)
  deliberately STAY in the app — they are SwiftTerm-output scrapers bound to the
  excluded terminal-hosting, depend on `PatternParser` (auto-handle infra), and are
  slated for retirement by the `claude auth login` button (#35); the module instead
  gets the pure `AuthCoordinator` reducer that consumes their signal output. The
  new auth core has landed: `AuthCoordinator` (OAuth-wins single-decision reducer,
  fixing the #30/#31 same-chunk flip-flop), an internal `ProcessRunner` subprocess
  seam (stdin+stderr→/dev/null so the single stdout read can't deadlock,
  watchdog-bounded, lock-guarded `timedOut`), and `ClaudeAuthInvoker` — which
  spawns claude's own `auth login`/`logout`/`status --json` under the account's
  config dir and observes the exit only (claude opens its own browser + runs its
  own OAuth callback; LogoSwitch never reads the URL, proxies the callback, or
  touches the token). The account model is now the launcher's: `AccountManager` is
  slimmed and moved into the module — the credential-capture path
  (`add(credentials:)` / `addByCapturingCurrent` / the `SystemKeychainBridge` read +
  `AccountCredentialStore` write) is gone, replaced by `createAccount(label:)` (an
  empty account the user signs in via `claude auth login`); persistence moves to
  `AccountStore` (legacy four-key compatible — no data loss); and the #31 staleness
  bugs are fixed (`setActive` clears the prior account's forced override,
  banner-dismiss `acknowledgeReauth` un-forces, a config-dir creation failure now
  throws so the spawn can be gated). The OAuth-authorize-URL detector tests were
  removed too — that scrape path (#17) is a dead end retired by `claude auth login`
  (#35), so a claude authorize URL no longer appears anywhere in the test suite.
  The now-dead `AccountCredentialStore` + `SystemKeychainBridge` (the system-keychain
  read + per-account token store — better-agent-terminal's exact anti-pattern) are
  DELETED with their tests: the app now has **zero** claude-credential keychain
  access anywhere (no `import Security` / `SecItem*` / `security find-/add-generic-
  password`), verified comment-aware by `RedLineAuditTests`. The app glue now
  routes the two passive-detector signals through `AuthCoordinator` (one arbitrated
  decision per chunk, OAuth-initiated strictly wins — bug #3 flip-flop gone),
  banner-Dismiss calls `acknowledgeReauth` (bug #4), and a config-dir-creation
  failure blocks the spawn instead of launching claude into a phantom dir (bug #6).
  Login stays in claude's own hands — there is **no Logos "sign in" button**. You
  sign in the way you would in any terminal: run `/login` in the hosted claude for
  the active account (claude opens its own browser; the #33 hydrated env makes that
  work). The switcher shows only a non-blocking "needs login" indicator. (An earlier
  per-account Sign-in button that shelled `claude auth login` was removed as
  redundant + off-philosophy — Logos is a transparent host of claude, not an auth
  driver.) Settling the philosophy ("LogoSwitch just switches config profiles; auth
  is claude's own job"), Logos reads auth state **only** from the live terminal-401
  signal — it runs no `claude auth` subcommands behind the scenes — so
  `ClaudeAuthInvoker` + `ProcessRunner` are removed. `AccountManager`/`AccountStore`
  are now slimmed to that live-401-only `needsReauth`: the dead
  `authenticatedAccountIds` flag, `.credentials.json` probe, migration, and
  `markAuthenticated`/`markNeedsReauth` are gone (persistence is just the account
  list + active selection), which **honestly closes #32** — the unwired
  needs-reauth lifecycle was removed, not papered over. Remaining follow-ups: retire
  the #17 URL scrape + the passive detectors once claude's own browser-open is
  confirmed on the #33 hydrated env (#35), then the 6-AI verify + close of #34.
  (This bullet records the in-progress journey across several commits; it'll be
  condensed to the final shipped shape in #34's closing summary.)

### Fixed

- **"claude CLI not found" on a normal Finder/Spotlight launch** ([#33](https://github.com/PsychQuant/logos/issues/33), P1).
  A GUI app launched from Finder inherits the bare launchd environment (PATH =
  `/usr/bin:/bin:/usr/sbin:/sbin` — no `~/.local/bin`, no homebrew), so the old
  bare `which claude` failed and claude spawned (when it spawned at all) with an
  impoverished env. Logos now hydrates the user's **login-shell environment**
  once per launch (a new `LoginShellEnvironment`: `$SHELL -ilc` with a
  sentinel-delimited `/usr/bin/env -0` dump, stdin=/dev/null, 3 s watchdog,
  graceful fallback to the process env — the VS Code `shell-env` pattern) and
  uses it both to **find** claude (PATH search, with the bare `which` as last
  resort) and to **spawn** it (`baseEnvironment`), so claude runs exactly as it
  would inside Ghostty/Terminal.app. Per-account `CLAUDE_*` isolation (#12) is
  layered on top of the hydrated env and locked by a regression test. Whether
  the richer env also fixes claude's own `/login` browser-open (the #17
  detector's reason to exist) is a post-fix verification, not assumed.

### Changed

- **Hardened the passive re-auth banner detection** ([#30](https://github.com/PsychQuant/logos/issues/30), Phase A).
  Two robustness fixes to the #29 banner. (1) Both passive detectors
  (`LoginPromptDetector` #29 + `OAuthURLDetector` #17) now scan a new bounded,
  reset-immune `RollingTerminalBuffer` instead of the auto-handle `PatternParser`
  buffer, which is `reset()` on every rule match — so a 401 / OAuth URL split
  across two PTY chunks with a reset interleaved is no longer dropped. (2)
  `LoginPromptDetector` now fires on the **rising edge** (`absent → present`)
  rather than a one-shot latch, so a genuinely new 401 re-surfaces the banner
  while still never storming. A new Coordinator-level test asserts the
  split-signal-survives-reset flow end-to-end. (3) The 6-AI verify (Codex
  cross-model) caught that `OAuthURLDetector.detect` examined only the *first*
  authorize-URL token — so with the longer-retained buffer an already-opened
  URL could **shadow** a genuinely new one (e.g. a failed login that
  re-prompts); it now scans past stale/seen tokens to the first unseen URL.
  Still first-party-safe (read output → flip flag; no token touch). Auto-clear
  on successful re-auth + `needsAuth`↔`needsReauth` coherence (an existing
  today-incoherence under a stale `.credentials.json`) are deferred to
  [#31](https://github.com/PsychQuant/logos/issues/31) (they need claude's
  post-login success string, which isn't knowable from the codebase).

### Added

- **Passive re-auth banner for an unauthenticated hosted claude** ([#29](https://github.com/PsychQuant/logos/issues/29)).
  When the active account's per-account credentials are missing/expired, the
  genuine claude prints a raw `401 · Please run /login` and the user was frozen
  with no guidance. A new `LoginPromptDetector` (sibling of `OAuthURLDetector`)
  scans the ANSI-stripped PTY buffer for that signal and flips a
  `TerminalSessionState.needsAuth` flag, surfacing a non-blocking top banner —
  "This account isn't signed in — type `/login`" — with a dismiss. **First-party-safe
  by design** (the constraint that shaped the fix): it is passive — Logos never
  injects `/login`, proxies the OAuth callback, or touches the token; the genuine
  claude owns the entire auth lifecycle (the existing `OAuthURLDetector` opens the
  browser). Detector + state are unit-tested; the banner clears on restart /
  dismiss (auto-clear on successful re-auth is a documented follow-up).

- **Dangerous-mode launch toggle** ([#19](https://github.com/PsychQuant/logos/issues/19)).
  Settings → Advanced → Permissions adds a toggle that launches claude with
  `--dangerously-skip-permissions` (bypass all permission prompts). Default OFF
  with an inline warning. A persisted `AdvancedSettings.dangerouslySkipPermissions`
  (back-compat: optional `PersistedDTO` field so a legacy `advanced.json` still
  decodes — a non-optional field would reset all advanced settings) feeds the
  existing `ClaudeProcessConfig.extraArgs` hook via a `claudeExtraArgs` computed
  property; takes effect on new sessions / after a restart (#18).

- **Terminal exit-state overlay (no more frozen pane after `/quit`)** ([#18](https://github.com/PsychQuant/logos/issues/18)).
  claude was spawned directly as the PTY leader with no termination handling, so
  exiting it (`/quit` / `/exit`) left a frozen, unusable pane. The terminal now
  overrides `processTerminated` and surfaces it through an `@Observable`
  `TerminalSessionState`, overlaying a Ghostty-faithful exit state — "claude
  exited (code N)" with **Restart claude** / **Close window** — over the last
  output instead of freezing. Restart bumps a generation counter folded into the
  terminal view's SwiftUI `.id`, re-spawning a fresh claude with a fresh
  detector/parser and re-materialized per-account credentials (so #12 isolation
  and #17 OAuth auto-open survive a restart). Clean-exit path only; a future crash
  watchdog branches on `TerminalSessionState.isAbnormal`. The state machine is
  unit-tested (`TerminalSessionStateTests`); the overlay/respawn wiring is
  interactive-only (the SwiftTerm view cannot be instantiated in `swift test`).

### Changed

- **Terminal adopts the fork's Metal GPU renderer (C.2 moat)** (`renderer-c2-metal-adoption`).
  The terminal view now enables the SwiftTerm fork's existing Metal renderer
  (`setUseMetal(true)` with per-row persistent buffering) once it is attached to a
  window, routing output through the GPU vsync draw loop with damage coalescing
  instead of the CoreGraphics draw-immediately path that presented a transient
  blank frame between a Claude clear and its reprint (~22 mid-state clusters per
  12 redraw cycles measured on CoreGraphics — see
  `docs/renderer-baselines/cg-vs-metal-edit-tool.md`). Hardware without Metal
  falls back to CoreGraphics (no regression). This supersedes the from-scratch
  renderer-rewrite plan; the moat is delivered by adoption. The enable/skip/once/
  fallback logic is unit-tested via `MetalAdoptionPolicy`; the live tearing-removal
  result is confirmed by interactive validation on the running app (the SwiftTerm
  view cannot be instantiated in `swift test`).

- **BREAKING (internal): multi-account credential isolation** ([#12](https://github.com/PsychQuant/logos/issues/12)).
  Account switching no longer writes the shared system Keychain entry
  (`Claude Code-credentials`). The cross-identity `SecItem` write that could
  trigger the macOS 26 "找不到鑰匙圈" reset dialog is removed entirely —
  `SystemKeychainBridge` is now read-only (`write`/`delete` deleted), and
  `AccountManager.setActive` / `remove` perform no Keychain access at all.
  Instead, each account spawns `claude` with its own `CLAUDE_CONFIG_DIR` and
  `CLAUDE_SECURESTORAGE_CONFIG_DIR` (both set to `~/.logos/accounts/<id>/.claude`),
  so claude stores that account's credentials in its OWN per-directory Keychain
  item (`Claude Code-credentials-<hash>`) and Logos never touches the shared
  entry. Switching is now pure local state.

  needs-reauth is surfaced per account in the switcher from promptless signals
  only — a Logos-owned authenticated flag plus a `.credentials.json` file check,
  never a Keychain read. A one-time, non-destructive migration on first launch
  ensures each account's config dir exists and marks existing accounts
  needs-reauth; the bare `Claude Code-credentials` entry is left untouched so a
  plain-terminal `claude` keeps working.

  **Migration**: existing multi-account users re-run `claude login` once per
  account to populate its per-directory credential. The credential service-name
  scheme was confirmed by source-level inspection of claude v2.1.156 (see #12).
  Suite 170/170.

### Internal

- **Test pyramid: smoke + E2E layers above the unit base** (`testing-smoke-e2e-strategy`,
  [#23](https://github.com/PsychQuant/logos/issues/23),
  [#24](https://github.com/PsychQuant/logos/issues/24)). Closes the GUI blind spot
  that #17–#22 verified by screenshot. **Track A (headless smoke)**: a `make smoke`
  target launches the bundled app and asserts the critical flow (launch → workspace
  load → claude spawn → exit) by reading the `os.Logger` trail via `UnifiedLogReader`
  — no pixels, no TCC. **Track B (UI E2E)**: a thin XcodeGen-generated Xcode project
  (`project.yml`; `Logos.xcodeproj` gitignored) hosts an `XCUITest` target (the #20
  Settings-open regression) and an app-hosted `LogosHostedTests` target that
  instantiates the SwiftTerm view a bare `swift test` can't (the Metal renderer
  window-attachment wiring, #23). Apple Development signing — macOS 26 Gatekeeper
  rejects an ad-hoc XCUITest runner as "damaged". CI (`.github/workflows/ci.yml`):
  `swift test` hard gate + a best-effort `e2e` job that degrades with a warning
  where the runner lacks claude / a signing identity. #24 added accessibility
  identifiers + a `--claude-path` test hook that makes claude spawn under XCUITest
  (gated behind a `--ui-testing` co-flag so it is inert in production, and taking
  precedence over a persisted Settings override so a UI test resolves claude on a
  dev machine); its behavior flows (Restart / toggle / account switch) are deferred
  to [#27](https://github.com/PsychQuant/logos/issues/27) (the XCUITest runner is
  sandboxed — no `kill` / `log show` to drive exit or assert; the flows instead
  drive exit by typing `/quit` into the PTY). Snapshot testing →
  [#26](https://github.com/PsychQuant/logos/issues/26); cloud-CI signing →
  [#25](https://github.com/PsychQuant/logos/issues/25). `swift test` 217/217 +
  `xcodebuild test` green.

- **Consolidated diagnostic logging onto `os.Logger` + lifecycle log points**
  ([#22](https://github.com/PsychQuant/logos/issues/22)). Logging was split across
  three mechanisms — `os.Logger` (1 site), `NSLog` (2 sites), and a `print`
  (1 site, the `materializeHomeTree` failure path whose stdout vanishes for a GUI
  app). All now route through a single `Log` factory (`Sources/Logos/Services/Log.swift`)
  exposing one `Logger` per category (`terminal` / `account` / `session` /
  `renderer` / `settings` / `workspace`) under the shared `app.getlogos.logos`
  subsystem. Lifecycle events (claude spawn/exit, session phase/restart, account
  switch/migrate/materialize, settings changes) are logged at `.notice` so they
  persist to the unified-log store and are queryable with zero GUI / zero TCC:
  `log show --predicate 'subsystem == "app.getlogos.logos"'`. Privacy follows
  `os.Logger`'s default redaction — only non-sensitive scalars (exit code, bool,
  enum case, counts, generation) are `.public`; account ids, paths, errors, and
  env stay `<private>`. A `LoggingHygieneTests` source-scan guards against new
  `NSLog`/`print` regressions. Suite 206/206.

- **Test hygiene** ([#10](https://github.com/PsychQuant/logos/issues/10)). (a)
  `WorkspaceModelTests` no longer write to `UserDefaults.standard` — model
  construction now goes through an isolated-suite helper, so a save side-effect
  in one test can't bleed into another's `loadLastPath()` assertion. (b) The
  sync `openWorkspace` test now asserts its previously-untested persistence
  side-effect (`loadLastPath() == openedPath`). (c) `loadAsync_doesNotBlockCaller`
  was a placebo — its 200-flat-file fixture walked in <5ms, so a main-blocking
  loader would have passed too; it now uses a ~2500-entry/5-level tree and
  snapshots the MainActor sentinel's tick count *at load completion* (the real
  off-main discriminator). Suite 161/161.

- **Docs/cosmetic cleanup** ([#11](https://github.com/PsychQuant/logos/issues/11)).
  (a) `WorkspaceLoader.maxFiles`/`maxDepth` gained doc-comments clarifying that
  `maxFiles` counts *entries visited* (dirs + missing-file races), not strict
  leaf-file count, and `maxDepth` counts the root as depth 1 (no rename — the
  names are load-bearing across callers). (b) The loading `ProgressView` overlay
  is confined to the editor content area so it no longer overlaps the status
  bar; the `#9` error banner is unchanged. (c) `WorkspacePersistence`'s
  `@unchecked Sendable` doc now states the safety is in-process only. (d)
  `MainScene` reads workspace persistence through the shared `WorkspaceModel`
  (`workspacePersistence`) instead of constructing a second instance — one
  source of truth. (e) README gained a "Local data & privacy" note (the
  `UserDefaults` plist is readable by other unsandboxed local processes;
  standard macOS behaviour, no secrets stored there). Behaviour-preserving;
  suite 161/161.

### Fixed

- **`claude login` can save credentials again — no more 「找不到鑰匙圈來儲存」 dialog** ([#21](https://github.com/PsychQuant/logos/issues/21)).
  For #12's per-account isolation, Logos spawned claude with `HOME` overridden to the
  per-account dir (`~/.logos/accounts/<id>/`). But macOS resolves the login keychain via
  `$HOME` (`$HOME/Library/Keychains/login.keychain-db`), and the per-account home has none —
  so claude's credential `SecItemAdd` failed with the macOS "找不到鑰匙圈來儲存「<user>」"
  reset dialog and the login couldn't persist. The HOME override is removed: the keychain is
  per-login-user, so per-account isolation needs only `CLAUDE_CONFIG_DIR` +
  `CLAUDE_SECURESTORAGE_CONFIG_DIR` (both unchanged) — never a per-account HOME. claude's
  config/history stays isolated via `CLAUDE_CONFIG_DIR` regardless of HOME. Root cause
  confirmed by reproduction (`HOME=<empty-dir> security add-generic-password` triggers the
  exact dialog; real HOME succeeds).

- **Settings window no longer crashes on open** ([#20](https://github.com/PsychQuant/logos/issues/20)).
  The `Settings` scene is separate from the main `WindowGroup` and does not inherit
  its environment, but `SettingsWindow`'s tabs read `@Environment(Type.self)`
  (`GeneralSettings` / `TerminalConfig` / `AutoHandleEngine` / `AdvancedSettings` /
  `WorkspaceModel`) with nothing injected — so opening Settings (⌘,) trapped
  (`EnvironmentValues.subscript.getter` assertionFailure → `EXC_BREAKPOINT`/SIGTRAP).
  The shared `@Observable` models are now owned by `LogosApp` (App-level `@State`)
  and injected into BOTH scenes, so Settings opens and edits the same instances the
  app uses. Pre-existing bug, surfaced by the first-ever Settings open (while testing
  #19's toggle). Full env set is injected so adding an `@Environment` to a tab later
  can't silently re-introduce the crash.

- **`claude login` browser now opens automatically** ([#17](https://github.com/PsychQuant/logos/issues/17)).
  claude prints the login OAuth URL but its own browser-open (npm `open` → macOS
  `open`) does not foreground a browser from Logos's spawned-PTY launchd session,
  so users had to copy a ~400-char URL by hand on every account login (every
  account is needs-reauth after the #12 credential-isolation migration). Logos
  now detects the claude authorize URL in its existing PTY stream-tee
  (`OAuthURLDetector`) and opens it via `NSWorkspace`. The detector is locked to
  `claude.com` + `/cai/oauth/authorize` (never a general URL opener), reassembles
  a terminal-wrapped URL, and opens each distinct URL once.

- **Launch hang on Finder/Spotlight start** ([#2](https://github.com/PsychQuant/logos/issues/2))
  — GUI-launched Logos froze on a loading spinner because
  `MainScene.autoLoadWorkspaceIfNeeded` used `FileManager.default.currentDirectoryPath`
  as the default workspace; for GUI processes that path is `/`, so the
  loader recursed the entire filesystem on the main thread.

  Three-prong fix (commits `ed5e839` → `1aa171d` → `f00e8c8`):

  - **`WorkspaceLoader` safety limits** — new `maxDepth` (default 10)
    and `maxFiles` (default 50,000) parameters; absolute-path skip set
    drops any child whose resolved real path matches `/System`, `/Library`,
    `/private`, `/usr`, `/Volumes`, `/dev`, `/etc`, `/var`, `/bin`,
    `/sbin`, `/cores`; root `/` (and entries in the skip set) refused
    outright with `LoaderError.refusedSystemPath`; `LoaderError` gained
    `.tooManyFiles(found:cap:)` for the catastrophic-input defence line.
  - **Async loader + loading state** — `WorkspaceLoader.loadAsync` runs
    the walk in `Task.detached(.userInitiated)` so MainActor stays
    responsive; `WorkspaceModel.openWorkspaceAsync` publishes an
    `isLoading` flag and cancels the previous in-flight load when a new
    call arrives; `MainView` overlays a `ProgressView` on `.thinMaterial`
    while loading.
  - **Last-workspace persistence** — new
    `Sources/Logos/Services/WorkspacePersistence.swift` stores the
    last-opened path in `UserDefaults` under
    `logos.lastWorkspacePath`; `MainScene` reads it on launch (clearing
    stale entries whose path no longer exists) and falls back to a
    welcome empty state when nothing is stored. `cwd` is no longer
    consulted at any point.

  12 new tests; full suite 125/125 pass. Smoke-verified against the
  Developer-ID-signed + notarized v0.1.0 build.

- **TCC dialog cascade when opening home (`~`) as a workspace**
  ([#7](https://github.com/PsychQuant/logos/issues/7)). Selecting `~` at
  Cmd+O made `WorkspaceLoader` recurse into `~/Documents`, `~/Desktop`,
  `~/Library/*` etc.; each TCC-protected directory's first
  `contentsOfDirectory` call triggered a modal macOS consent dialog,
  producing a cascade of prompts and an indefinitely-stuck loading spinner.
  `absoluteSkipPaths` only covered system roots, never user-home-relative
  paths.

  `WorkspaceLoader` now derives a user-relative TCC skip set
  (`Documents`, `Desktop`, `Downloads`, `Pictures`, `Music`, `Movies`,
  `Library`, `.Trash`) from an injectable `homeDirectory` (default
  `NSHomeDirectory()`) and drops those directories **as children** during
  the walk — so opening `~` no longer cascades, while explicitly choosing a
  protected directory as the workspace root (e.g. `~/Documents`) still walks
  it normally (one expected prompt for the user-chosen folder). The skip
  filter resolves symlinks, so a symlink pointing at a TCC path is caught
  too. 3 new tests; full suite 131/131 pass.

  Scope note: this fixes the common entry point (opening `~`). The skip set
  holds top-level home directories only, and the chosen root is never
  filtered — so explicitly opening a TCC directory (or a directory whose
  deeper subtree holds TCC content, e.g. `~/Library` or `~/Pictures`) as the
  workspace root can still cascade. A TCC-resilient walk that handles
  protected directories at any depth and surfaces skipped dirs to the user
  is tracked as a follow-up.

- **Path-safety hardening: resolved/firmlink forms, `/opt`, canonicalization**
  ([#6](https://github.com/PsychQuant/logos/issues/6)). `WorkspaceLoader`'s
  system-path defence used exact-set membership, so a symlink resolving to
  `/private/var` (the canonical form of `/var`) or a firmlink like `/usr/local`
  slipped past, and `/opt/homebrew` (100k+ files) hit the `maxFiles` fail-fast.

  Replaced exact-match with a two-class classifier (`isSystemPath`):
  **prefix-block** pure-system trees (`/System`, `/Library`, `/usr`, `/bin`,
  `/sbin`, `/dev`, `/cores`, `/Network`, `/opt`) at any depth — catching
  `/usr/local` firmlinks and `/opt/homebrew`; **exact-block** `/`, `/Volumes`,
  `/private`, `/var`, `/tmp`, `/etc` — so a symlink→`/var` (which `canonical()`
  collapses to `/var`, the short form macOS standardizes to) is caught while
  legitimate descents (`/Volumes/MyDrive/code`, scratch dirs under
  `/var/folders`) are still allowed. `normalize()` replaced by `canonical()`
  (`resolvingSymlinksInPath().standardizedFileURL` — collapses `//`, resolves
  `.`/`..`). The exact-block stores **canonical short forms** (`/var`, not
  `/private/var`) because every comparison runs `canonical()` first, and on
  macOS `canonical("/private/var") == "/var"` (collapse to shortest), not the
  reverse — an end-to-end regression test guards `load("/var"|"/etc"|"/tmp")`.

  Scoped out (per plan): generalized firmlink volume-boundary detection via
  `.volumeIdentifierKey`. The prefix-block covers the known firmlink roots
  (`/usr/local` etc.); a full cross-volume-boundary refuse is a separate,
  riskier mechanism (could block legitimate user data on a secondary APFS
  volume) deferred until there's a demonstrated need.

- **TCC-resilient walk at any depth; protected dirs surfaced not dropped**
  ([#13](https://github.com/PsychQuant/logos/issues/13)). #7 only stopped the
  cascade for opening `~`; opening `~/Library` (or `~/Pictures`) directly as a
  root still descended into `~/Library/Mail` etc. And #7 *silently dropped*
  the skipped dirs.

  `WorkspaceLoader` now (a) matches TCC paths at any depth — the depth-1 home
  set, the whole `~/Library` subtree, and package extensions
  (`.photoslibrary`/`.musiclibrary`/`.tvlibrary`); (b) **surfaces** TCC dirs as
  opaque protected leaves (`FileNode.isProtected`, shown dimmed + locked +
  non-expandable in the sidebar) instead of dropping them — no silent omission;
  (c) wraps `contentsOfDirectory` in a graceful catch so any unforeseen
  permission-denied directory also becomes a protected leaf; (d) guards a
  degenerate `homeDirectory` (`""` / `"/"`) by disabling TCC filtering rather
  than poisoning the skip set. System paths (#6) are still dropped (never user
  content).

  This **supersedes #7's drop behavior with surface behavior** — the two #7
  TCC tests now assert the dirs are present with `isProtected == true` rather
  than absent. 8 net new tests; full suite 139/139.

- **Workspace-load cancellation now actually stops the walk** ([#4](https://github.com/PsychQuant/logos/issues/4)).
  `loadAsync` ran the walk in a `Task.detached`, which is cancellation-orphaned
  — `currentLoadTask.cancel()` only flipped the outer flag while the detached
  walk kept consuming disk I/O to completion (rapid Cmd+O queued unbounded I/O).
  A lock-guarded `CancelFlag` now bridges the awaiting task's cancellation into
  the walk via `withTaskCancellationHandler`; `walk` polls it between entries
  and throws `CancellationError`. The `isLoading` spinner's `defer` is
  epoch-guarded so a superseded load can't flip it off mid-walk (no flicker).

- **Workspace-load errors are surfaced, not silently swallowed** ([#9](https://github.com/PsychQuant/logos/issues/9)).
  `performLoad` previously `catch { return }` — TCC denial, permission errors,
  `refusedSystemPath`, `tooManyFiles` all produced a silent blank state with
  the broken path still persisted (repeating next launch). Now: a new
  observable `WorkspaceModel.lastError` (typed `WorkspaceLoadError` with a
  user-facing message) drives a dismissable banner in `MainView`; `os_log`
  records the failure; persistence is cleared only for definitively-stale
  errors (`notFound`/`notADirectory`/`refused`), not transient ones.
  `CancellationError` stays silent (not a failure). The per-child walk loop now
  skips non-fatal child errors (permission/EIO) instead of aborting the whole
  load — only `tooManyFiles`/`CancellationError` propagate. Persisted-path
  validation also checks **directory-ness** (`directoryExistsOffMain`) so a
  path that became a regular file is cleared instead of loading as a
  single-file root.

  9 net new tests; full suite 148/148. #4's cancellation test intent is
  satisfied deterministically via the `isCancelled` closure (no timing-based
  slow-loader stub).

- **Terminal launch workspace argument** ([#8](https://github.com/PsychQuant/logos/issues/8)).
  #2 removed cwd-based auto-load (the cwd=`/` walk was its root cause), which
  broke the dev convention of launching an editor in a project directory.
  Restored via an explicit launch argument — `Logos --workspace <path>` (or
  `open -a Logos --args --workspace <path>`) — plus a guarded current-directory
  fallback for direct-binary launches. Both the argument and the cwd must be
  **absolute** paths (a relative arg like `Sources` / `..` is rejected — it would
  resolve against the process cwd unpredictably) and are routed through
  `WorkspaceLoader.isSystemPath`, so `/`, `/Users` (the all-users container), and
  system roots are refused — a normal GUI launch (cwd=`/`) is unaffected and the
  unintended-large-tree walk class behind #2 stays closed. (`/Users` was added to
  the exact-block set here, which also hardens Cmd+O.) Precedence: `--workspace`
  arg → persisted → guarded cwd → welcome. The
  resolver (`MainScene.resolveLaunchWorkspace`) is a pure, injectable function;
  13 deterministic tests, suite 161/161. An ergonomic `logos .` CLI shim
  (mirroring `code .`) is noted as future work — `open <app>` does not propagate
  cwd, so the argument, not cwd-sniffing, is the robust mechanism.

  Note: this revises #2's "`cwd` is no longer consulted at any point" — cwd is
  now consulted only as a last-resort fallback for direct-binary launches, and
  only when it is a non-system directory.

### Changed

- **No more auto-import of `claude` credentials on first launch**
  ([#3](https://github.com/PsychQuant/logos/issues/3) — commit `15c36f8`).
  Previously `MainScene.onAppear` called `FirstLaunchAccountImport.runIfNeeded`,
  which on macOS 26 unsandboxed Developer-ID apps surfaced the legacy
  `找不到鑰匙圈來儲存「<user>」` modal dialog inside `SecItemAdd` /
  `SecItemUpdate`. The fallback "重置為預設值" button in that dialog is
  **system-level destructive** — it would create a new default `login.keychain`,
  cascading silent failures into Safari autofill, Wi-Fi 802.1X certs, Mail
  account creds, VPN, and any other app that stores credentials in the user's
  login keychain. Users seeing the dialog had no way to tell that was the
  consequence.

  Logos now defers credential import to an explicit user action: open
  Settings → Accounts → "Capture current login as new account" (the existing
  flow in `AccountSwitcherSheet`, unchanged). `FirstLaunchAccountImport.swift`
  is deleted; no other callers.

  Note this is a **behavioral mitigation**, not a structural fix of the
  underlying `SystemKeychainBridge` write path. `setActive(_:)` (multi-account
  swap) and the manual "Capture" button still call `SecItemAdd` / `SecItemUpdate`
  on `service = "Claude Code-credentials"` and *could* re-surface the same
  dialog under unfavorable macOS keychain state. Those user-gesture paths
  give the user context to interpret the dialog, unlike the unprompted
  launch-time surface. Long-term structural fix (re-architect to read-only
  system bridge + own access group) tracked as a follow-up.

  Hypothesis (a) (add `keychain-access-groups` entitlement) was tried first
  and **empirically falsified**: notarized cleanly but AMFI SIGKILLed the
  signed bundle at launch (exit=137) — restricted entitlements require an
  embedded provisioning profile that Developer ID distribution doesn't have.
  Commits `afc646a` (attempt) + `c25b3d6` (revert) preserved in history.

### Internal

- Initialized Spectra (spec-driven development scaffolding, commit `cbe9b4e`):
  `openspec/` directory, `.spectra.yaml`, `AGENTS.md`, `.agents/skills/`,
  CLAUDE.md `SPECTRA:START/END` block. Not yet exercised on any feature.

## [0.1.0] — 2026-05-25

Initial pre-release. Sub-plans A + B + C.1 + D + E + F + G + H complete
(see `README.md` for full feature matrix).
