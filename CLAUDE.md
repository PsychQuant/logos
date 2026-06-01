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
- **Manual log inspection** (what the smoke automates): launch the app, then
  `/usr/bin/log show --predicate 'subsystem == "app.getlogos.logos"'` (use the
  absolute path — `log` is a zsh builtin that shadows the binary and returns
  empty). `.notice` events persist; `.info`/`.debug` are stream-only.
- **CI** (`.github/workflows/ci.yml`): the `unit` job (`swift test`) is the hard
  gate and runs anywhere; the `e2e` job runs Track A + B but each degrades with a
  visible warning where the runner lacks `claude` / a signing identity — never a
  silent pass.
- **Snapshot baselines** (#26, `ViewSnapshotTests`): committed PNGs under
  `LogosHostedTests/__Snapshots__/` are recorded on a canonical machine with a
  pinned size + forced `.aqua` appearance. To regenerate after an intentional
  view change, delete the stale PNG(s) (or set `SNAPSHOT_TESTING_RECORD=all`) and
  re-run `xcodebuild test`. A different macOS version, Retina scale, or **system
  accent color** may not byte-match (`.aqua` pins light/dark but not the accent,
  which the active-account circle + prominent buttons track) — treat snapshots as
  a single-canonical-environment guard, not a cross-machine gate.

## Brand

Working name `Logos` (λόγος = word, reason, rational order). Trademark validation pending — see design doc § 12.
