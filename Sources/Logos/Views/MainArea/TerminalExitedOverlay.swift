import SwiftUI

/// Shown over the terminal pane when the hosted claude process exits
/// (PsychQuant/logos#18). Ghostty-faithful: the pane never freezes — exit
/// shows an intentional state with Restart / Close. The terminal's final
/// output stays visible behind this overlay (abnormal-exit output is not lost).
/// Styled to match `ClaudeNotFoundBanner` / `NoActiveAccountBanner`.
struct TerminalExitedOverlay: View {
    let exitCode: Int32?
    let isAbnormal: Bool
    let onRestart: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isAbnormal
                  ? "exclamationmark.triangle.fill"
                  : "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(isAbnormal ? .orange : .green)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            HStack(spacing: 12) {
                Button(action: onRestart) {
                    Label("Restart claude", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)  // Return restarts (Ghostty "press a key")
                .accessibilityIdentifier("logos.terminal.restart")  // #24 XCUITest query
                Button(role: .cancel, action: onClose) {
                    Label("Close window", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)   // Escape closes
                .accessibilityIdentifier("logos.terminal.close")    // #24 XCUITest query
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.85))
    }

    private var title: String {
        if let exitCode { return "claude exited (code \(exitCode))" }
        return "claude exited"
    }

    private var detail: String {
        isAbnormal
            ? "The session ended unexpectedly. Restart to continue, or close the window."
            : "The session ended. Restart claude or close the window."
    }
}
