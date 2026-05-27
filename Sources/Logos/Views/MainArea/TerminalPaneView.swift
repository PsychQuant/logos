import SwiftUI

struct TerminalPaneView: View {
    @Environment(TerminalConfig.self) private var config
    @Environment(AutoHandleEngine.self) private var engine
    @Environment(AccountManager.self) private var accountMgr

    var body: some View {
        Group {
            if let active = accountMgr.active,
               let claudePath = config.resolvedClaudePath {
                let processConfig = ClaudeProcessConfig(
                    executablePath: claudePath,
                    account: active
                )
                SwiftTermView(
                    config: config,
                    processConfig: processConfig,
                    engine: engine,
                    accountManager: accountMgr
                )
                .background(Color.black)
                .id(active.id)  // Force view recreation on account switch
            } else if accountMgr.active == nil {
                NoActiveAccountBanner()
            } else {
                ClaudeNotFoundBanner()
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
            Text("Install Claude Code and ensure 'claude' is in your $PATH.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
