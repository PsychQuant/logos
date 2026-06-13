import SwiftUI
import AppKit
import SwiftTerm
import os

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

            // #17: open the claude login OAuth URL natively. claude prints the
            // URL but its own browser-open (npm `open` → macOS `open`) does not
            // foreground a browser from Logos's spawned-PTY launchd session.
            // The detector is locked to the claude authorize URL and yields each
            // distinct URL once.
            if let loginURL = oauthDetector.detect(in: detectorBuffer.contents) {
                // Lifecycle marker (#22 follow-up): the OAuth login URL was detected
                // and is being opened natively (#17). The URL is default-redacted
                // (<private>) — it is a one-time login secret, never logged in clear.
                Log.terminal.notice("OAuth login URL detected, opening externally: \(loginURL.absoluteString)")
                NSWorkspace.shared.open(loginURL)
                // #31: a new authorize URL = re-auth INITIATED. Clear the passive
                // banner + un-force the switcher indicator. Optimistic (initiated,
                // not succeeded) — if the login fails, the next 401 re-fires both
                // via the rising edge. The active account is the one re-authing.
                sessionState.dismissNeedsAuth()
                accountManager.activeAccountId.map { accountManager.clearForcedReauth($0) }
            }

            // #29: surface a passive re-auth banner when the hosted claude reports
            // it's unauthenticated (401 / "Please run /login"). PASSIVE — we only
            // flip a UI flag; the genuine claude owns the whole auth lifecycle.
            if loginDetector.detect(in: detectorBuffer.contents) {
                Log.terminal.notice("hosted claude unauthenticated signal detected — surfacing re-auth banner (#29)")
                sessionState.markNeedsAuth()
                // #31: a live 401 → force the active account's needs-reauth so the
                // account-switcher indicator agrees with the banner (the static
                // authenticated-flag / .credentials.json signals can disagree).
                accountManager.activeAccountId.map { accountManager.forceReauth($0) }
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
                    // Could not write the per-account config dir — claude will
                    // likely fail to auth. Previously a `print` whose stdout
                    // vanished for a GUI app (#22 — the silent failure hole).
                    // account id + error description stay default-redacted (D3).
                    Log.terminal.error("failed to materialize config dir for account \(account.id): \(String(describing: error))")
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
