# Changelog

All notable changes to Logos are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

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

  11 new tests; full suite 125/125 pass. Smoke-verified against the
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
  and `/private` plus its canonical-resolved system forms (`/private/var`,
  `/private/tmp`, `/private/etc`) — so a symlink→`/var` is caught while
  legitimate descents (`/Volumes/MyDrive/code`, scratch dirs under
  `/private/var/folders`) are still allowed. `normalize()` replaced by
  `canonical()` (`resolvingSymlinksInPath().standardizedFileURL` — collapses
  `//`, resolves `.`/`..`).

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
