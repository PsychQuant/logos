import SwiftUI
import AppKit
import SwiftTerm
import os
import LogoSwitch

/// SwiftUI wrapper around SwiftTerm's LocalProcessTerminalView.
/// Owns the NSView; configures theme + font; spawns subprocess on appear.
/// Tees PTY bytes through PatternParser + AutoHandleEngine so known
/// claude prompts get auto-answered.
///
/// E-Task 5: accepts AccountManager so Coordinator can materialize the
/// per-account HOME tree (write creds with 0o600) BEFORE startProcess.
struct SwiftTermView: NSViewRepresentable {

    let config: TerminalConfig
    let processConfig: ClaudeProcessConfig
    let engine: AutoHandleEngine
    let accountManager: AccountManager
    let sessionState: TerminalSessionState
    /// #49 Part 2: reports the `--session-id` UUID this pane spawned claude with, so the
    /// status-bar usage model can read exactly `<uuid>.jsonl` instead of guessing
    /// newest-mtime. Fires once per real spawn (from the `hasStarted`-gated seam), on the
    /// main actor. Default no-op keeps non-usage callers (and previews) simple.
    var onSessionSpawned: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> TeedLocalProcessTerminalView {
        let view = TeedLocalProcessTerminalView(frame: .zero)
        // #78: this is the production creation site — inside an app-hosted
        // `xcodebuild test` the host app's real UI reaches here, so mark the view
        // to skip the real GPU Metal engagement. A directly-constructed test view
        // (RendererAdoptionTests) never passes through here, so it stays ungated.
        view.isHostedUnitTesting = HostedTestEnvironment.isHostedUnitTesting()
        TerminalThemeApplier.apply(config: config, to: view)
        view.onChunk = { [weak coord = context.coordinator] chunk in
            coord?.handleChunk(chunk)
        }
        view.onProcessTerminated = { [weak coord = context.coordinator] code in
            coord?.handleTermination(code)
        }
        context.coordinator.startIfNeeded(view)
        return view
    }

    func updateNSView(_ nsView: TeedLocalProcessTerminalView, context: Context) {
        // Re-apply theme if config changes (font/colors edited via Settings later)
        TerminalThemeApplier.apply(config: config, to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            processConfig: processConfig,
            engine: engine,
            accountManager: accountManager,
            sessionState: sessionState,
            onSessionSpawned: onSessionSpawned
        )
    }

    /// Owns subprocess start. Gated by `hasStarted` so SwiftUI re-rendering
    /// the wrapper view doesn't spawn duplicate child processes.
    @MainActor
    final class Coordinator {
        let processConfig: ClaudeProcessConfig
        let engine: AutoHandleEngine
        let accountManager: AccountManager
        let sessionState: TerminalSessionState
        /// #49 Part 2: reports the spawned session's `--session-id` UUID (see `SwiftTermView`).
        let onSessionSpawned: (String) -> Void
        let parser: PatternParser
        weak var view: TeedLocalProcessTerminalView?
        /// #84: `private(set)` so the spawn-gate tests can read the gate boundary
        /// (stays false when the #78 gate blocks, flips true when it opens) without
        /// widening the write surface.
        private(set) var hasStarted = false
        /// #78: when true, `startIfNeeded` skips spawning the real claude child.
        /// Defaults to the env probe (see `HostedTestEnvironment`) so ANY in-process
        /// unit-test host never spawns a live `--dangerously-skip-permissions`
        /// process — the ~2s-in bystander crasher behind RendererAdoptionTests.
        /// Injectable (settable) so a `swift test` can force it either way — the
        /// #84 spawn-gate tests drive `attemptStart` with this both true and false.
        var isHostedUnitTesting = HostedTestEnvironment.isHostedUnitTesting()

        /// #84 test seam: the PTY spawn side-effect — `view.startProcess` plus the
        /// spawn-lifecycle log — behind an injectable closure. `attemptStart` invokes
        /// it ONLY after the #78 gate passes, so a unit test overriding it observes
        /// whether the spawn was attempted (gate open) or skipped (gate closed)
        /// WITHOUT launching a real process or constructing a
        /// `TeedLocalProcessTerminalView` (which segfaults the bare `swift test`
        /// runner). Defaults to the real spawn against `self.view`; production is
        /// byte-identical when unset. Mirrors `metalEnabler` / `isHostedUnitTesting`.
        lazy var spawnProcess: (_ args: [String]) -> Void = { [weak self] args in
            guard let self, let view = self.view else { return }
            view.startProcess(
                executable: self.processConfig.executablePath,
                args: args,
                environment: self.processConfig.environment.map { "\($0.key)=\($0.value)" },
                execName: nil,
                currentDirectory: self.processConfig.workingDirectory
            )
            // Spawn lifecycle point (#22). Scalars only: arg count, dangerous-mode
            // flag, account-present — all non-sensitive → public. The executable
            // path and env stay off the log entirely (carry username / paths). The
            // session UUID is not secret but stays off the log to keep it scalars-only.
            Log.terminal.notice("spawned claude — args=\(args.count, privacy: .public) dangerous=\(args.contains("--dangerously-skip-permissions"), privacy: .public) account=\(self.processConfig.account != nil, privacy: .public)")
        }
        /// Opens the claude login OAuth URL natively (#17) — claude's own
        /// browser-open fails inside Logos's spawned-PTY launchd context.
        private var oauthDetector = OAuthURLDetector()
        /// Detects claude's unauthenticated signal (#29) to flip the passive
        /// re-auth banner. READ-ONLY — never touches the token.
        private var loginDetector = LoginPromptDetector()
        /// Reset-immune, bounded buffer that BOTH passive detectors scan (#30
        /// Item 1). The auto-handle engine still scans the `parser` buffer (which
        /// must keep resetting to avoid re-firing rules); feeding the detectors a
        /// buffer the reset never touches means a 401 / OAuth URL split across two
        /// chunks survives an interleaved `parser.reset()`.
        private var detectorBuffer = RollingTerminalBuffer()

        init(
            processConfig: ClaudeProcessConfig,
            engine: AutoHandleEngine,
            accountManager: AccountManager,
            sessionState: TerminalSessionState,
            onSessionSpawned: @escaping (String) -> Void
        ) {
            self.processConfig = processConfig
            self.engine = engine
            self.accountManager = accountManager
            self.sessionState = sessionState
            self.onSessionSpawned = onSessionSpawned
            self.parser = PatternParser()
        }

        /// The hosted claude process exited (#18). Flip session state to the
        /// exited phase so the SwiftUI layer shows the exit-state overlay
        /// instead of a frozen pane. CLEAN-exit path only — a future crash
        /// watchdog must branch on `sessionState.isAbnormal`.
        func handleTermination(_ exitCode: Int32?) {
            // PTY-level exit signal (#22). exit code is non-sensitive → public;
            // a signal-kill yields nil, logged as "signal".
            Log.terminal.notice("claude process exited — code=\(exitCode.map { String($0) } ?? "signal", privacy: .public)")
            sessionState.markExited(exitCode)
        }

        /// Called for each chunk the subprocess emits. Append to parser
        /// buffer, ask engine if any rule matches, inject response if so.
        func handleChunk(_ bytes: [UInt8]) {
            guard let text = String(bytes: bytes, encoding: .utf8) else { return }
            let buffered = parser.append(text)
            // #30: feed the reset-immune detector buffer the raw chunk. The
            // passive detectors below scan this (not `buffered`), so an
            // auto-handle `parser.reset()` can't drop a split signal's first half.
            detectorBuffer.append(text)

            // #30/#31/#34: collapse the two passive-detector signals into ONE
            // decision per chunk via AuthCoordinator. Both detectors still run each
            // chunk (advancing their rising-edge state), but only the single
            // arbitrated decision acts — so a chunk holding both an authorize URL
            // AND a stale 401 can't clear-then-re-force (the flip-flop, bug #3:
            // OAuth-initiated strictly wins).
            let signals = AuthSignals(
                oauthURL: oauthDetector.detect(in: detectorBuffer.contents),
                live401: loginDetector.detect(in: detectorBuffer.contents)
            )
            switch AuthCoordinator.decide(signals) {
            case .reauthInProgress(let loginURL):
                // #17 fallback: claude's own browser-open can fail in Logos's
                // launchd PTY session, so open the authorize URL natively. The URL
                // stays <private> (a one-time secret); the public scalars surface a
                // truncated reassembly without leaking it. Re-auth INITIATED → clear
                // banner + un-force the active account. (This scrape path is slated
                // for retirement by the `claude auth login` Sign-in button, #35.)
                Log.terminal.notice("OAuth login URL detected, opening externally — len=\(loginURL.absoluteString.count, privacy: .public) hasRedirectURI=\(loginURL.absoluteString.contains("redirect_uri"), privacy: .public): \(loginURL.absoluteString)")
                NSWorkspace.shared.open(loginURL)
                sessionState.dismissNeedsAuth()
                // #42: clear re-auth for THIS pane's account (per-window), not the
                // global active — a 401 belongs to the account this pane spawned.
                processConfig.account.map { accountManager.clearForcedReauth($0.id) }
            case .needsReauth:
                // Live 401 → passive re-auth banner (#29) + force the active
                // account's needs-reauth so the switcher agrees with it (#31).
                Log.terminal.notice("hosted claude unauthenticated signal detected — surfacing re-auth banner (#29)")
                sessionState.markNeedsAuth()
                // #42: force re-auth on THIS pane's account (per-window-correct).
                processConfig.account.map { accountManager.forceReauth($0.id) }
            case .none:
                break
            }

            if let response = engine.processChunk(buffered) {
                // Inject into PTY stdin via the LocalProcess.
                view?.process.send(data: ArraySlice(response))
                // Reset buffer so we don't re-fire on the same text on
                // the next chunk.
                parser.reset()
            }
        }

        func startIfNeeded(_ view: TeedLocalProcessTerminalView) {
            // Store the view, then run the (view-free) gate + spawn logic. The split
            // lets a unit test drive `attemptStart` — and the #78 spawn gate —
            // without constructing a `TeedLocalProcessTerminalView` (which segfaults
            // the bare `swift test` runner). Production is unaffected: the gate is
            // open there (`isHostedUnitTesting` false), so this is identical in effect
            // to a single fused method — the same `self.view` assignment precedes the
            // same spawn.
            self.view = view
            attemptStart()
        }

        /// The #78 spawn gate + subprocess start, factored out of `startIfNeeded` so a
        /// unit test can exercise the gate decision without a terminal view. The real
        /// PTY spawn is reached only through the `spawnProcess` seam (against
        /// `self.view`), so a test with a nil view / overridden seam observes whether
        /// the spawn was attempted without launching a process.
        func attemptStart() {
            guard !hasStarted else { return }
            // #78: in a host process running in-process unit tests, the production
            // UI that reaches this seam must NOT spawn the real
            // `--dangerously-skip-permissions` claude child — it's a live privileged
            // process inside `xcodebuild test` and the ~2s-in bystander crasher
            // behind RendererAdoptionTests. Return before any spawn-side effect
            // (config-dir materialization, session-id binding, `startProcess`),
            // leaving `hasStarted` false so nothing half-initializes.
            if isHostedUnitTesting { return }
            hasStarted = true

            // E-Task 5: materialize HOME tree for active account before spawn.
            // Without this, claude reads from an empty dir and triggers OAuth.
            if let account = processConfig.account {
                do {
                    try accountManager.materializeHomeTree(for: account)
                } catch {
                    // bug #6: a failed config dir means claude would launch into a
                    // phantom CLAUDE_CONFIG_DIR and present a spurious login for an
                    // account the user believes is set up. Do NOT spawn — surface
                    // the re-auth banner and allow a retry on the next render
                    // (account id + error stay default-redacted, #22 D3).
                    Log.terminal.error("failed to materialize config dir for account \(account.id): \(String(describing: error))")
                    sessionState.markNeedsAuth()
                    hasStarted = false
                    return
                }
            }

            // #49 Part 2: bind this spawn to a fresh session id so the status bar reads
            // exactly this session's transcript (`<uuid>.jsonl`) rather than newest-mtime.
            // Generated HERE — the single per-spawn seam (`hasStarted`-gated) — not in
            // `ClaudeProcessConfig` (recreated on every SwiftUI render): claude hard-errors
            // "Session ID is already in use" on a reused id, so exactly one fresh UUID per
            // real spawn is required. Lowercased so the flag value, claude's on-disk
            // `<uuid>.jsonl`, and the reader's case-sensitive filename match by construction.
            let (spawnArgs, reportedSessionId) = Self.sessionSpawnArgs(
                base: processConfig.arguments,
                sessionId: UUID().uuidString.lowercased()
            )

            // Real PTY spawn + spawn-lifecycle log, behind the #84 seam so a test can
            // observe the gate opened without launching a process.
            spawnProcess(spawnArgs)

            // Report the bound session id AFTER a successful spawn so the usage model only
            // binds to a session that actually started (the failure path above returns early).
            // `nil` when the caller supplied its own `--session-id` → usage stays on the
            // newest-mtime fallback rather than binding to an id we can't be sure of.
            if let reportedSessionId {
                onSessionSpawned(reportedSessionId)
            }
        }

        /// Build the spawn argv, appending a fresh `--session-id <sessionId>` UNLESS the caller
        /// already bound one (opt-in via `extraArgs`). Pure + `internal` so a unit test can
        /// assert the injection without launching a PTY. Returns the argv plus the id to report
        /// to the usage model — `nil` when the caller supplied its own, so nothing auto-binds.
        static func sessionSpawnArgs(base: [String], sessionId: String) -> (args: [String], reportedId: String?) {
            if base.contains("--session-id") {
                return (base, nil)
            }
            return (base + ["--session-id", sessionId], sessionId)
        }
    }
}
