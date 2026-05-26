import SwiftUI

struct TerminalPaneView: View {
    @Environment(TerminalConfig.self) private var config
    @Environment(AutoHandleEngine.self) private var engine

    var body: some View {
        Group {
            if let claudePath = config.resolvedClaudePath {
                let processConfig = ClaudeProcessConfig(executablePath: claudePath)
                SwiftTermView(config: config, processConfig: processConfig, engine: engine)
                    .background(Color.black)
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
