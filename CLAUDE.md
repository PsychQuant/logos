<!-- SPECTRA:START v1.0.2 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `/spectra-*` skills when:

- A discussion needs structure before coding → `/spectra-discuss`
- User wants to plan, propose, or design a change → `/spectra-propose`
- Tasks are ready to implement → `/spectra-apply`
- There's an in-progress change to continue → `/spectra-ingest`
- User asks about specs or how something works → `/spectra-ask`
- Implementation is done → `/spectra-archive`
- Commit only files related to a specific change → `/spectra-commit`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? Plan mode → `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `/spectra-apply` and `/spectra-ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

# Logos — Claude Code conventions

## What this project is

Native macOS app (Swift / SwiftUI) that hosts the `claude` CLI with native UI, auto-recovery, multi-account, and zero render tearing. See [`docs/design/2026-05-25-logos-design.md`](docs/design/2026-05-25-logos-design.md) for the full design.

## Working directory map

```
logos/
├── README.md                      ← public-facing summary
├── CLAUDE.md                      ← this file (Claude Code conventions)
├── LICENSE                        ← TBD (intent: MIT)
├── docs/
│   └── design/
│       └── 2026-05-25-logos-design.md   ← THE design doc — read first
└── (no Swift code yet — design phase)
```

Spectra (`openspec/`) will be initialized once open design questions are resolved. Until then, treat `docs/design/2026-05-25-logos-design.md` as the source of truth.

## Reading order

1. `docs/design/2026-05-25-logos-design.md` § 1-6 (overview, philosophy, layout, features)
2. § 7 (architecture decisions — especially renderer rewrite)
3. § 9 (MVP scope — what's in v1.0 vs later)
4. § 10 (open questions — these block implementation)
5. § 11 (non-goals — what NOT to build)

## When working on this project

- **Defer implementation** until open questions in design § 10 are answered
- **Sister project context**: `/Users/che/Developer/claude-code-logos/` is the plugin marketplace under the same brand — different repo, shared philosophy
- **Predecessor context**: `/Users/che/Developer/claude-code-watchdog/` is the bash watchdog whose pattern-detection logic ports forward into Logos' auto-recovery system

## Coding conventions (when code lands)

- Swift 6, SwiftPM
- SwiftUI for new UI, AppKit interop only when SwiftUI lacks capability
- Min macOS: TBD (likely 14+ for new SwiftUI APIs)
- Notarization via `che-mcps-notary` keychain profile (existing pipeline per `~/.claude/CLAUDE.md`)
- No emoji in code or comments unless explicitly requested by user

## Testing

The test pyramid is two-layered above the unit/integration base (the global
`common-testing.md` baseline of Unit + Integration + E2E). Both layers below ARE
the project's E2E coverage; Track B grows incrementally.

| Layer | Command | What it asserts | Needs |
|-------|---------|-----------------|-------|
| Unit + Integration | `swift test` (or `make tests`) | logic, models, parsers, persistence, logging hygiene; the pure `UnifiedLogReader` parse | nothing special |
| Track A — headless smoke / E2E | `make smoke` | the critical flow (launch → workspace load → claude spawn → exit) by reading the `os.Logger` trail — no pixels | the `claude` CLI |
| Track B — UI E2E (XCUITest) | `xcodegen generate` then `xcodebuild test -project Logos.xcodeproj -scheme Logos -destination 'platform=macOS'` | pixel-level behavior logs can't prove (Settings opens without crashing — the #20 regression) | XcodeGen + an Apple Development signing identity |
| Hosted view tests (XCTest) | same `xcodebuild test` (target `LogosHostedTests`) | the Metal renderer window-attachment wiring (#23) + SwiftUI **snapshot** baselines for stable views (#26) — instantiates views a bare `swift test` segfaults on | XcodeGen + signing (app-hosted; `swift-snapshot-testing`) |

Notes:

- **Track A is gated**: the app-launching `Smoke` suite only runs under
  `LOGOS_SMOKE=1` (set by `make smoke`), so a plain `swift test` never launches
  the app. The `UnifiedLogReader` parse test runs in every `swift test`.
- **Track B needs Apple Development signing.** macOS 26 Gatekeeper rejects an
  ad-hoc-signed XCUITest runner as "damaged" and refuses to launch it, which
  blocks `xcodebuild test`. `project.yml` signs with the generic
  `Apple Development` identity (resolves to your keychain's dev cert). Install
  XcodeGen once with `brew install xcodegen`. `Logos.xcodeproj` is a generated
  artifact (gitignored) — `project.yml` is the source of truth; SwiftPM
  (`Package.swift`) remains the source of truth for the app build itself.
- **Track B needs the Metal Toolchain** (macOS 26 / Xcode 26). It ships as a
  separate downloadable component, not with the base toolchain. The Logos app
  target has Metal renderer shaders, so an app-hosted `xcodebuild` build
  (`make hosted-tests` / Track B, both the renderer and snapshot tests) fails with
  `cannot execute tool 'metal' due to missing Metal Toolchain` until it is
  installed: `xcodebuild -downloadComponent MetalToolchain` (~688 MB, once per
  machine). A plain `swift test` never touches Metal, so this is a hosted/Track-B
  prerequisite only — alongside `brew install xcodegen` and the Apple Development
  signing identity above.
- **`project.yml` ↔ `Package.swift` drift guard** (#65): `Tests/BuildGraphDriftTests`
  runs in the plain `swift test` hard gate and fails if any `Package.swift` library
  target (`.target(name:)`) is missing from `project.yml`'s `targets:`. It closes
  the blind spot where extracting a `Sources/` module without mirroring it in
  `project.yml` silently broke Track B (`import <Module>` unresolvable under
  `xcodebuild`) yet left `swift test` green — the #39 / #60 recurrence.
- **Manual log inspection** (what the smoke automates): launch the app, then
  `/usr/bin/log show --predicate 'subsystem == "app.getlogos.logos"'` (use the
  absolute path — `log` is a zsh builtin that shadows the binary and returns
  empty). `.notice` events persist; `.info`/`.debug` are stream-only.
- **CI** (`.github/workflows/ci.yml`): the `unit` job (`swift test --enable-code-coverage`)
  is the hard gate and runs anywhere; the `e2e` job runs Track A + B but each
  degrades with a visible warning where the runner lacks `claude` / a signing
  identity — never a silent pass.
- **CI signing secrets** (#25): Track B runs in cloud CI when two repo secrets are
  set (Settings → Secrets and variables → Actions) — `APPLE_CERT_P12_BASE64`
  (`base64 -i AppleDevelopment.p12 | pbcopy`) + `APPLE_CERT_PASSWORD` (the `.p12`
  export password). `apple-actions/import-codesign-certs` imports them into an
  ephemeral keychain so `xcodebuild test` runs signed. **Maintainer-only** — secrets
  can't be set by an agent, and forked PRs can't read them (they keep the
  degrade-with-warning path). Without the secrets Track B is local-only.
  **Entitlement caveat**: the signed run uses `-allowProvisioningUpdates` + Manual
  signing and works today only because the target has zero profile-requiring
  entitlements (no sandbox / hardened-runtime / `CODE_SIGN_ENTITLEMENTS`). If the
  app gains any such capability, `xcodebuild` will hard-fail *inside* the signed
  branch (CI has no App Store Connect API key to mint a profile) — add an
  API-key / provisioning-profile step then, don't expect the degrade path to catch it.
- **Coverage is report-only** (#25): CI prints `Sources/Logos` line coverage vs the
  80% bar + a `::warning::` when under, but never fails the build. Locally:
  `make coverage`. The `swift test` number **undercounts** a SwiftUI app — view
  bodies + AppKit interop execute only under the `xcodebuild` hosted/UI run
  (`make hosted-tests` / Track B), a separate profdata. A hard 80% gate on the
  unit-only number is deferred until coverage approaches the bar (flip the warning
  to `exit 1` in `ci.yml`).
- **Snapshot baselines** (#26, `ViewSnapshotTests`): committed PNGs under
  `LogosHostedTests/__Snapshots__/` are recorded on a canonical machine with a
  pinned size + forced `.aqua` appearance. **Perceptual tolerance** (#73): the
  single `snapshot()` helper compares at `.image(precision: 0.98,
  perceptualPrecision: 0.98)`, not raw bytes. `perceptualPrecision: 0.98` routes
  swift-snapshot-testing off its `precision >= 1 && perceptualPrecision >= 1`
  raw-byte short-circuit into `perceptuallyCompare`, where a pixel counts as
  "different" only if its CIELAB Delta-E exceeds `(1 - 0.98) * 100 = 2` — just
  above the ~1 ΔE just-noticeable-difference. `precision: 0.98` caps the
  fully-mismatching fraction at 2% of pixels (an anti-aliased edge pixel can spike
  past ΔE 2, so precision must also drop below 1, not just perceptualPrecision).
  **Absorbs**: OS point-update anti-aliasing / font-rendering drift (the #73 case
  — 4 baselines byte-mismatched with no visible difference after a macOS point
  update, all ΔE well under 2). **Still catches**: real layout/color regressions
  (wrong accent, moved/missing element, a background or button color change) —
  they perturb far more than 2% of pixels and/or at ΔE well above 2, so they stay
  RED (verified #73 by a deliberate black→blue background perturbation). Caveat on
  the floor: a *very* small-area change (e.g. a single word swapped in one centred
  title line) can fall under the 2% budget and pass — tolerance trades some
  small-text sensitivity for OS-drift durability. To regenerate after an
  intentional view change, delete the stale PNG(s) (or set
  `SNAPSHOT_TESTING_RECORD=all`), re-run `xcodebuild test` to record, then re-run
  to assert; re-record stays the fallback for a major visual overhaul that the
  tolerance would (correctly) RED. Because XcodeGen globs `LogosHostedTests/` as
  resources, run `xcodegen generate` after deleting PNGs (so the project stops
  referencing them) and again after recording. A different Retina scale or
  **system accent color** can still exceed the tolerance (`.aqua` pins light/dark
  but not the accent, which the active-account circle + prominent buttons track) —
  the tolerance widens the guard across OS point updates but it remains a
  canonical-environment guard, not a full cross-machine gate.
- **XCUITest behavior flows** (#27, `LogosUITests/`): the runner sandbox blocks
  `Process` (no `kill`/`log show`), so flows drive state + assert via pure UI.
  Three `--ui-testing`-gated test seams (inert in production — the arg never appears):
  (1) `--seed-accounts <csv>` injects keychain-free stub accounts into a *volatile*
  UserDefaults suite (`LogosApp.makeAccountManager`), so a fresh launch renders the
  terminal + has switchable accounts without touching the keychain or the real
  account list; (2) a `logos.terminal.uitestTerminate` affordance drives the clean
  exit overlay via a click (`markExited(0)`) since the runner can't `kill` claude;
  (3) `--seed-remove-fails` (#67) chmods the volatile accounts-index dir read-only
  (`0o500`) after seeding, so a delete's registry persist genuinely fails and rolls
  back (`remove()` → false) — driving `AccountDeleteFailureUITests`' flows, which
  hard-assert the `logos.account.delete.error` caption and record edit-mode
  retention as an observation only (the #68 assertion-scoping decision; observed
  RETAINED on the canonical machine, round 3); (4) a per-row
  `logos.account.beginRename` pencil affordance, because **XCUITest cannot
  synthesize SwiftUI's `.onTapGesture(count: 2)`** — element/coordinate doubleClick
  and two rapid clicks all leave the recognizer unfired, while a real hardware
  double-click works (verified out-of-band, commit `a2f2fc1`) — so rename flows
  drive the exact `onBeginRename` callback through it. **Query row controls by
  VoiceOver LABEL, not identifier** — the ratified permanent convention (#79, option
  a): the row's `logos.account.row` id shadows every child control's id at runtime, so
  the trash / open-in-new-window / pencil buttons are each queried by their VoiceOver
  label, never by their (shadowed) identifier; the child ids are kept only as intent
  markers (relocating the row id off the HStack — option b — was rejected as a
  restructure for marginal benefit). The account-label `Text` itself carries
  `.isButton` (#77 — VoiceOver activate = select, with a "Rename" custom action in the
  actions rotor), which promotes its XCUIElementType from `.staticText` to `.button`,
  so the account label is queried via `buttons[label]`, NOT `staticTexts[label]`.
  **Local Track B prerequisite**: macOS Developer Mode must be enabled
  (`DevToolsSecurity -status`; enable via `sudo DevToolsSecurity -enable`) — with it
  disabled, every XCUITest run times out at "enabling automation mode" before any
  test code executes. Known flake: `RendererAdoptionTests` can crash its first
  hosted phase and pass on xcodebuild's retry, leaving a confusing aggregate
  `** TEST FAILED **` with all suites green (#78).
  Decision (#27): the exit is driven by the affordance, **not** type-to-stdin
  `/quit` — a keychain-free seeded account yields an unauthenticated claude (a
  login prompt, not a `/quit`-able REPL). The "no keychain dialog appeared"
  negative stays a documented best-effort Residue (XCUITest can't prove a system
  dialog *didn't* show); the account flow asserts positives (indicator moved, app
  alive) only.

## Brand

Working name `Logos` (λόγος = word, reason, rational order). Trademark validation pending — see design doc § 12.
