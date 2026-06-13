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

    func makeNSView(context: Context) -> TeedLocalProcessTerminalView {
        let view = TeedLocalProcessTerminalView(frame: .zero)
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
            sessionState: sessionState
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
        let parser: PatternParser
        weak var view: TeedLocalProcessTerminalView?
        private var hasStarted = false
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
            sessionState: TerminalSessionState
        ) {
            self.processConfig = processConfig
            self.engine = engine
            self.accountManager = accountManager
            self.sessionState = sessionState
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
                accountManager.activeAccountId.map { accountManager.clearForcedReauth($0) }
            case .needsReauth:
                // Live 401 → passive re-auth banner (#29) + force the active
                // account's needs-reauth so the switcher agrees with it (#31).
                Log.terminal.notice("hosted claude unauthenticated signal detected — surfacing re-auth banner (#29)")
                sessionState.markNeedsAuth()
                accountManager.activeAccountId.map { accountManager.forceReauth($0) }
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
            guard !hasStarted else { return }
            hasStarted = true
            self.view = view

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

            view.startProcess(
                executable: processConfig.executablePath,
                args: processConfig.arguments,
                environment: processConfig.environment.map { "\($0.key)=\($0.value)" },
                execName: nil,
                currentDirectory: processConfig.workingDirectory
            )
            // Spawn lifecycle point (#22). Scalars only: arg count, dangerous-mode
            // flag, account-present — all non-sensitive → public. The executable
            // path and env stay off the log entirely (carry username / paths).
            Log.terminal.notice("spawned claude — args=\(self.processConfig.arguments.count, privacy: .public) dangerous=\(self.processConfig.arguments.contains("--dangerously-skip-permissions"), privacy: .public) account=\(self.processConfig.account != nil, privacy: .public)")
        }
    }
}
