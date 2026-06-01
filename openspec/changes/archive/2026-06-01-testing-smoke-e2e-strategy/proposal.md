## Why

Logos's test pyramid covers Unit and partial Integration (206 tests) but has zero automated Smoke or E2E coverage — every GUI-layer change in #17–#22 had to be verified by screenshot or manual `ps` / `log show` because runtime behavior had no scripted, assertable trail. `SwiftTermView` (an `NSViewRepresentable`) cannot even be instantiated inside `swift test` (it segfaults without a window server), so the spawn → host → exit → restart flow — the app's single most critical user flow — is untested. This violates the project's testing baseline (Unit + Integration + E2E required). PsychQuant/logos#22 just built the foundation that makes headless E2E possible: an `os.Logger` lifecycle trail queryable via the `app.getlogos.logos` subsystem. This change turns that trail into automated assertions and adds a window-server-hosted UI test layer for the pixel-level behavior logs cannot prove.

## What Changes

- Add a **headless smoke / E2E layer (Track A)**: a SwiftPM test target that launches the bundled `.app` as a subprocess with launch args, then asserts the expected lifecycle sequence by querying the unified-log store (`log show --style json`, subsystem `app.getlogos.logos`). Asserts that behavior fired — no window server needed beyond launching the app, no TCC, CI-friendly. Exposed via a `make smoke` target and kept out of the default `swift test`.
- Add a **UI E2E layer (Track B)**: a thin, XcodeGen-generated Xcode project (spec checked in, project gitignored) hosting an `XCUITest` target. SwiftPM stays the source of truth for the app; the Xcode project exists only to host UI tests and window-server-hosted view tests. Asserts pixel-level behavior logs cannot prove (window renders, controls clickable, overlay drawn). First anchor test is the #20 Settings-open regression.
- Add three lifecycle `.notice` points so the smoke sequence is fully assertable: app-launch-finished, workspace-load-success (today only logged on failure), and OAuth-URL-detected. All follow the #22 privacy posture (only non-sensitive scalars public).
- Add **CI**: two jobs — `swift test` (unit + integration + headless smoke) and `xcodebuild test` (XCUITest on a window-server runner). No CI exists today.
- Document the strategy in CLAUDE.md, declaring Track A + Track B as the project's E2E layer and recording Track B's incremental-growth expectation.

## Capabilities

### New Capabilities

- `lifecycle-observability`: critical user-flow lifecycle events are emitted as queryable `os.Logger` `.notice` signals with a defined privacy posture, and are covered by automated smoke (headless, log-trail) and E2E (UI) assertions.

### Modified Capabilities

(none)

## Impact

- Affected code:
  - New: Tests/LogosSmokeTests/SmokeTests.swift
  - New: Tests/LogosSmokeTests/UnifiedLogReader.swift
  - New: project.yml
  - New: LogosUITests/SettingsLaunchUITests.swift
  - New: .github/workflows/ci.yml
  - Modified: Package.swift
  - Modified: Makefile
  - Modified: .gitignore
  - Modified: Sources/Logos/Services/Log.swift
  - Modified: Sources/Logos/App/LogosApp.swift
  - Modified: Sources/Logos/Models/WorkspaceModel.swift
  - Modified: Sources/Logos/Terminal/SwiftTermView.swift
  - Modified: CLAUDE.md
- Dependencies: XcodeGen (new dev-time tool for generating the Xcode project from project.yml); no new app runtime dependency.
- Systems: introduces an Xcode build path (xcodebuild) alongside SwiftPM; introduces CI where none existed.
