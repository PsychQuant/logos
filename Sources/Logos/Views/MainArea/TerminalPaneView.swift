import SwiftUI
import AppKit

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
        let effectivePath = advanced.claudePathOverride ?? config.resolvedClaudePath

        Group {
            if let active = accountMgr.active, let claudePath = effectivePath {
                let processConfig = ClaudeProcessConfig(
                    executablePath: claudePath,
                    account: active,
                    extraArgs: advanced.claudeExtraArgs  // #19: dangerous-mode toggle
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
