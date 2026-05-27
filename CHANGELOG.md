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
