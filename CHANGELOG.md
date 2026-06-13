# Changelog

All notable changes to Logos are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
  gets the pure `AuthCoordinator` reducer that consumes their signal output. Still
  to come: the new `ProcessRunner` + `ClaudeAuthInvoker` + `AuthCoordinator`, the
  slimmed `AccountManager`, and the removal of the token-capture path
  (`addByCapturingCurrent` / `AccountCredentialStore` / `SystemKeychainBridge`).

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
