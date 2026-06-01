## 1. Lifecycle log points (foundation for smoke assertions)

- [x] 1.1 Emit an app-launch-finished `.notice` once the main scene is up, so a launch marker is queryable in the unified-log store; add a dedicated `Log` category if needed (in Log.swift / LogosApp.swift). Verify: launch the bundled app and confirm the launch-finished record appears under `log show --predicate 'subsystem == "app.getlogos.logos"'`. (Spec requirement: Critical lifecycle events are observable via the unified log.)
- [x] 1.2 [P] Emit a workspace-load-success `.notice` on the success path in WorkspaceModel (count public, path default-redacted), complementing the existing failure-path `.error`. Verify: a WorkspaceModel test (or log assertion) confirms a success record with `<private>` path on a successful load.
- [x] 1.3 [P] Emit an OAuth-URL-detected `.notice` when OAuthURLDetector fires in SwiftTermView (URL default-redacted), where today `NSWorkspace.open` runs with no log. Verify: feed the detector a known login URL and confirm a `.notice` record is emitted with the URL `<private>`.
- [x] 1.4 Keep the privacy posture intact for the new points and the hygiene guard green. Verify: `swift test` stays green (206+) and `LoggingHygieneTests` passes (no NSLog/print/os_log/Swift.print/debugPrint added). (Spec requirement: Lifecycle log payloads follow the redaction posture.)

## 2. Track A — headless smoke harness

- [x] 2.1 [P] Provide a `UnifiedLogReader` helper that returns decoded lifecycle events (category, level, message) for the `app.getlogos.logos` subsystem by shelling the absolute `/usr/bin/log show --style json` with a predicate and timeout. Verify: a focused test asserts the reader parses a known query result into typed events (and uses the absolute log path, not the shadowed builtin).
- [x] 2.2 Add a `LogosSmokeTests` SwiftPM target whose smoke test launches the bundled app against a temporary workspace and asserts the lifecycle sequence (launch, workspace load, claude spawn, process exit, restart) via `UnifiedLogReader`, tolerating claude auth failure and killing the launched app in teardown. Verify: the smoke test passes against a freshly built bundle with no authenticated account, and fails (reporting observed events) when an expected record is absent. (Spec requirement: A headless smoke test asserts the critical lifecycle flow.)
- [x] 2.3 Add a `make smoke` target that builds the bundle then runs only the smoke target, and keep the smoke target out of the default `swift test` run (env trait or separate target). Verify: `make smoke` exercises the harness while a plain `swift test` does not launch the app and stays at its existing duration/scope.

## 3. Track B — XcodeGen-generated UI E2E

- [x] 3.1 [P] Add a `project.yml` (XcodeGen) describing the app target (referencing the local SwiftPM package) plus a `LogosUITests` XCUITest target, and gitignore the generated `.xcodeproj`. Verify: `xcodegen generate` produces a project that `xcodebuild -list` shows with the app scheme and the `LogosUITests` target, and the generated project is untracked by git.
- [x] 3.2 Add the first UI anchor test in `LogosUITests` that launches the app, opens the Settings window, and asserts the window appears within a short timeout while the app process stays alive — the PsychQuant/logos#20 regression contract. Verify: `xcodebuild test` runs the UI target and the test passes (and would fail if Settings crashed or never appeared). (Spec requirement: A UI end-to-end test asserts pixel-level critical behavior.)

## 4. CI and documentation

- [x] 4.1 Add a `.github/workflows/ci.yml` with two jobs: one running `swift test` (unit + integration) on a macOS runner, and one running the smoke + `xcodebuild test` UI layer on a window-server runner, with the UI job degrading explicitly (never silently passing) where no window server is available. Verify: the workflow is green on a clean checkout, with both jobs visible in the run.
- [x] 4.2 Document the two-track test strategy in CLAUDE.md: how to run `make smoke` and the XcodeGen install + generate + `xcodebuild test` steps, and record that Track A + Track B constitute the project's E2E layer with Track B growing incrementally. Verify: content review confirms a contributor can run both layers from the documented steps alone.
