## Context

Logos is a SwiftPM executable (not an Xcode project) — a native macOS SwiftUI app that hosts the `claude` CLI in an embedded SwiftTerm PTY. Current tests: 34 files / 206 swift-testing cases, all Unit + partial Integration, in a single `LogosTests` target. There is no Smoke or E2E layer, no CI, and `SwiftTermView` (an `NSViewRepresentable`) segfaults if instantiated inside the `swift test` process because there is no window server / NSApplication drawable context. The single most critical user flow — open workspace, spawn claude, exit, restart — is therefore untested, which is why #17–#22 each needed manual screenshot / `ps` / `log show` verification (the "GUI blind spot").

PsychQuant/logos#22 standardized diagnostic logging onto `os.Logger` under the `app.getlogos.logos` subsystem and added lifecycle `.notice` points (claude spawn/exit, session phase/restart, account switch/materialize, settings changes). `.notice` persists to the unified-log store, so behavior is now queryable after the fact with `log show --predicate 'subsystem == "app.getlogos.logos"'` — zero GUI, zero TCC. That trail is the foundation this change builds on.

Constraints: the project's testing baseline requires Unit + Integration + E2E. CI does not exist yet (greenfield). Notarization runs through the existing `che-mcps-notary` pipeline; app bundling is hand-rolled in the Makefile (manual Info.plist copy + ad-hoc sign).

## Goals / Non-Goals

**Goals:**

- A headless smoke / E2E layer (Track A) that launches the real bundled app and asserts the critical lifecycle sequence by reading the os.Logger trail — CI-friendly, no window-server-pixel dependency, no TCC, no real credentials.
- A UI E2E layer (Track B) able to assert pixel-level behavior the log trail cannot prove (window renders, controls clickable, overlay drawn), anchored by the #20 Settings-open regression.
- Keep SwiftPM as the source of truth for the app build; introduce the Xcode build path only as a thin, generated host for UI tests.
- Three additional lifecycle `.notice` points so the smoke sequence is fully assertable end to end.
- CI that runs both layers, establishing the project's first automated pipeline.

**Non-Goals:**

- A full XCUITest suite up front. Track B ships infra + 1–2 anchor tests and grows incrementally.
- Converting the app build from SwiftPM to an Xcode project. The Xcode project hosts tests only.
- Pixel-perfect snapshot-image baselines. Out of scope; revisit only if visual regressions recur.
- Asserting that claude successfully authenticates. Smoke asserts the spawn → exit → restart lifecycle and tolerates claude's own auth failure (no real credentials in CI).
- Changing any app runtime behavior. The only source edits are additive log points.

## Decisions

**D1 — Track A harness is a SwiftPM test target driving the bundled app + asserting on the log store; not a shell script.**
A new `LogosSmokeTests` target uses `Process` to launch `.build/Logos.app`'s binary with launch args (a temp test workspace), then a single `UnifiedLogReader` helper shells `/usr/bin/log show --style json --predicate 'subsystem == "app.getlogos.logos"'`, decodes the JSON, and asserts the expected `.notice` sequence with a polling timeout via swift-testing `#expect`.
- Alternatives: (a) a standalone shell `make smoke` script — rejected as primary because it adds a second language and ad-hoc parsing, though it remains the fallback if the app cannot be driven from within the test process; (b) driving the app through XCUITest only — rejected because it forces the heavier Xcode path for behavior that logs already prove.
- The absolute `/usr/bin/log` path is mandatory: in the project shell `log` resolves to a builtin that shadows the binary and silently returns empty.

**D2 — Track B is an XcodeGen-generated, thin Xcode project (spec checked in, project gitignored).**
A `project.yml` (XcodeGen) describing the app + an `LogosUITests` XCUITest target is committed; the generated `.xcodeproj` is gitignored and produced on demand and in CI. SwiftPM stays the source of truth for the app; the Xcode project depends on the local SwiftPM package and exists only to host UI tests (and, later, window-server-hosted view tests for the SwiftTermView class).
- Alternatives: (a) hand-checked-in `.xcodeproj` — rejected: high drift, two manually-maintained build descriptions; (b) Tuist — rejected: heavier than needed for one UI-test target; (c) full conversion to Xcode project — rejected: loses SwiftPM ergonomics for no benefit to the app build.

**D3 — Smoke asserts lifecycle, tolerates claude auth failure.**
The smoke harness asserts the observable sequence (app launched → workspace loaded → claude spawned → process exited → restart) using the `.notice` events. It does NOT require claude to authenticate; a launched claude that fails auth still emits spawn + exit, which is what the harness checks. This keeps Track A runnable in CI without secrets.

**D4 — Smoke stays out of the default `swift test`.**
The smoke target is gated behind a `make smoke` target and/or an environment trait so a plain `swift test` (the fast unit/integration loop) does not launch a real app. Rationale: launching the bundle is slow, needs the bundle built, and is a different failure class than unit tests.

**D5 — Add three lifecycle `.notice` points, reusing the #22 privacy posture.**
New points: app-launch-finished (a top-level marker), workspace-load-success (today only the failure path logs), and OAuth-URL-detected (today `NSWorkspace.open` fires with no log). All `.notice`, only non-sensitive scalars marked public (counts, bools), paths/ids left default-redacted — identical discipline to #22. A new `Log` category may be added for the app-level marker.

**D6 — CI is two jobs.**
Job 1: `swift test` (unit + integration) on a macOS runner — runs anywhere. Job 2: the smoke + `xcodebuild test` UI layer on a macOS runner that has a window server (GitHub `macos-latest` qualifies). If a hosted runner cannot drive Metal/SwiftTerm, the UI job degrades to a self-hosted / manual-trigger job while smoke still runs where a window server is available.

**D7 — Build sequencing: Track A before Track B.**
Even though both layers land in this change, the order is: (1) the three `.notice` points, (2) Track A headless smoke + `make smoke`, (3) the XcodeGen thin wrapper + 1–2 anchor XCUITests, (4) CI workflows. Track A delivers immediate coverage at the lowest cost and is not blocked by Xcode infra.

## Implementation Contract

**Behavior / observable outcomes:**

- Running `make smoke` builds the bundle, launches it against a temp workspace, and exits non-zero unless the lifecycle `.notice` sequence is observed in the unified-log store within a timeout. On success it prints the matched sequence.
- The app emits these queryable `.notice` events (subsystem `app.getlogos.logos`): app-launch-finished, workspace-load-success (with a path-private / count-public payload), claude spawned, claude process exited, session restart, account materialize/switch, settings changed, OAuth-URL-detected. (The first three rows are new in this change; the rest exist from #22.)
- Running the UI test target (via `xcodebuild test` on the generated project) launches the app, opens the Settings window, and asserts the Settings window exists without the app process dying — the #20 regression.

**Interfaces / shapes:**

- `UnifiedLogReader` (smoke support): a helper exposing something like `events(subsystem:since:timeout:) -> [LogEvent]` where `LogEvent` carries category, level, and message, decoded from `log show --style json`. It is the single adapter over the log CLI — no second shell layer stacked on top.
- `project.yml`: XcodeGen spec declaring the app target (referencing the local SwiftPM package) and the `LogosUITests` XCUITest target. The generated `.xcodeproj` is a build artifact, not committed.
- A `make smoke` target and a CI workflow with two named jobs.

**Failure modes:**

- Smoke timeout (expected sequence not observed) → test fails with the events actually captured, for diagnosis.
- claude auth failure → tolerated; spawn + exit still satisfy the assertion.
- Window server unavailable on a runner → the UI job is skipped/degraded with an explicit message, never silently passes.
- `/usr/bin/log` not used (builtin shadow) → would silently return empty; the helper hard-codes the absolute path to prevent this.

**Acceptance criteria:**

- `swift test` still green (206+) and unchanged in scope (the smoke target is excluded from the default run).
- `make smoke` passes against a freshly built bundle and fails if any expected lifecycle `.notice` is missing.
- The UI anchor test opens Settings and asserts the window exists (fails if the app crashes or the window never appears — the #20 contract).
- CI runs both jobs and is green on a clean checkout.

**Scope boundaries:**

- In scope: the smoke target + `UnifiedLogReader`, the three new `.notice` points, the XcodeGen `project.yml` + one UI-test target with 1–2 anchor tests, the CI workflow, Makefile + .gitignore + Package.swift edits, and CLAUDE.md documentation.
- Out of scope: a full UI suite, snapshot-image baselines, converting the app build to Xcode, real-credential E2E, and any app runtime behavior change beyond additive log points.

## Risks / Trade-offs

- [Contributors / CI must have XcodeGen installed to build the Xcode project] → Mitigation: gitignore the generated project, generate it in the CI UI job, and document the one-line install + generate step in CLAUDE.md. The SwiftPM unit/integration loop needs no XcodeGen.
- [Hosted macOS CI runner may lack a usable window server for Metal/SwiftTerm] → Mitigation: smoke assertions tolerate the CoreGraphics fallback (the Metal-engaged `.notice` is not a required element of the sequence); if `xcodebuild test` cannot run on the hosted runner, degrade Track B's CI job to self-hosted / manual and keep Track A in CI.
- [Smoke flakiness from log-store timing / eventual consistency] → Mitigation: poll with a timeout over the persisted `.notice` level (not stream-only `.info`/`.debug`); kill the launched app in teardown to avoid zombie processes across runs.
- [claude binary absent or unauthenticated in CI] → Mitigation: assert spawn-attempt + exit rather than auth success; allow a fake/stub executable path via launch arg so the lifecycle fires deterministically without the real CLI.
- [Dual build path (SwiftPM + xcodebuild) drift] → Mitigation: XcodeGen regenerates from `project.yml` referencing the SwiftPM package, so the app build is described once; the Xcode project only adds the test target.

## Migration Plan

1. Add the three lifecycle `.notice` points (additive, no behavior change); extend `LoggingHygieneTests` / smoke expectations accordingly.
2. Add the `LogosSmokeTests` SwiftPM target + `UnifiedLogReader`; wire a `make smoke` target; keep it out of the default `swift test`.
3. Add `project.yml` (XcodeGen) + the `LogosUITests` target with the #20 Settings anchor test; gitignore the generated project.
4. Add the CI workflow with the two jobs; document the strategy and the XcodeGen install/generate step in CLAUDE.md.
