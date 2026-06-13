import SwiftUI
import AppKit
import LogoSwitch

struct TerminalPaneView: View {
    @Environment(TerminalConfig.self) private var config
    @Environment(AdvancedSettings.self) private var advanced
    @Environment(AutoHandleEngine.self) private var engine
    @Environment(AccountManager.self) private var accountMgr
    /// Lifecycle of the hosted claude session (#18). Drives the exit-state
    /// overlay and the generation-based restart. Owned here so it survives the
    /// view recreation that a restart triggers.
    @State private var sessionState = TerminalSessionState()

    var body: some View {
        // H-Task 9: AdvancedSettings.claudePathOverride wins over PATH lookup.
        // #24: a `--ui-testing --claude-path` launch arg wins over everything so a
        // UI test's claude resolves even on a dev machine with a persisted override
        // (uiTestingClaudePath is nil outside a UI test → no production effect).
        let effectivePath = TerminalConfig.uiTestingClaudePath()
            ?? advanced.claudePathOverride
            ?? config.resolvedClaudePath

        Group {
            if let active = accountMgr.active, let claudePath = effectivePath {
                let processConfig = ClaudeProcessConfig(
                    executablePath: claudePath,
                    account: active,
                    extraArgs: advanced.claudeExtraArgs,  // #19: dangerous-mode toggle
                    // #33: spawn claude with the user's REAL (login-shell) env, not
                    // the bare launchd env a Finder launch provides. Per-account
                    // CLAUDE_* overrides are layered on top inside the init (#12).
                    baseEnvironment: LoginShellEnvironment.resolve()
                )
                SwiftTermView(
                    config: config,
                    processConfig: processConfig,
                    engine: engine,
                    accountManager: accountMgr,
                    sessionState: sessionState
                )
                .background(Color.black)
                // Recreate on path / account / restart. The generation suffix
                // makes Restart re-spawn a fresh claude (fresh detector/parser +
                // re-materialized creds) by changing the view identity (#18).
                .id("\(active.id)-\(claudePath)-\(sessionState.generation)")
                .overlay {
                    if sessionState.hasExited {
                        TerminalExitedOverlay(
                            exitCode: sessionState.exitCode,
                            isAbnormal: sessionState.isAbnormal,
                            onRestart: { sessionState.restart() },
                            onClose: { NSApplication.shared.keyWindow?.performClose(nil) }
                        )
                    }
                }
                // #27: a launch-arg-gated terminate affordance. The XCUITest runner
                // sandbox blocks `Process` (can't kill claude's child to drive exit),
                // so a UI test drives the clean-exit overlay via this click instead —
                // it calls the exact `markExited(0)` transition `processTerminated`
                // drives. Inert in production (the `--ui-testing` arg never appears).
                .overlay(alignment: .topLeading) {
                    if CommandLine.arguments.contains("--ui-testing") {
                        Button("⏚") { sessionState.markExited(0) }
                            .accessibilityIdentifier("logos.terminal.uitestTerminate")
                            .padding(6)
                    }
                }
                // #29: passive re-auth nudge when the hosted claude is
                // unauthenticated (detected from its 401 / "Please run /login"
                // output). Non-blocking top strip — the terminal stays usable so
                // the user types `/login` themselves; Logos never touches the token.
                .overlay(alignment: .top) {
                    if sessionState.needsAuth {
                        AuthNeededBanner(onDismiss: { sessionState.dismissNeedsAuth() })
                    }
                }
            } else if effectivePath == nil {
                ClaudeNotFoundBanner()
            } else {
                NoActiveAccountBanner()
            }
        }
    }
}

private struct ClaudeNotFoundBanner: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("claude CLI not found")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Install Claude Code and ensure 'claude' is in your $PATH, or set the path explicitly in Settings → Advanced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Link(
                "Install instructions →",
                destination: URL(string: "https://docs.claude.com/en/docs/claude-code/")!
            )
            .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}

private struct NoActiveAccountBanner: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("No active account")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Add an account from the status bar (👤) to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}

/// #29: passive, non-blocking re-auth nudge. PASSIVE BY DESIGN — it only tells the
/// user to type `/login`; it does NOT run the login, proxy the OAuth callback, or
/// touch the token. The genuine `claude` owns the whole auth lifecycle (and
/// `OAuthURLDetector` opens the browser). Keeps Logos a first-party host, not a
/// third-party auth client.
private struct AuthNeededBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This account isn't signed in")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Type `/login` in the terminal to authenticate with Claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .accessibilityIdentifier("logos.terminal.authBanner")
    }
}
