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

## Brand

Working name `Logos` (λόγος = word, reason, rational order). Trademark validation pending — see design doc § 12.
