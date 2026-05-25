import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's LocalProcessTerminalView.
/// Owns the NSView; configures theme + font; spawns subprocess on appear.
struct SwiftTermView: NSViewRepresentable {

    let config: TerminalConfig
    let processConfig: ClaudeProcessConfig

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        TerminalThemeApplier.apply(config: config, to: view)
        context.coordinator.startIfNeeded(view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Re-apply theme if config changes (font/colors edited via Settings later)
        TerminalThemeApplier.apply(config: config, to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(processConfig: processConfig)
    }

    /// Owns subprocess start. Gated by `hasStarted` so SwiftUI re-rendering
    /// the wrapper view doesn't spawn duplicate child processes.
    @MainActor
    final class Coordinator {
        let processConfig: ClaudeProcessConfig
        weak var view: LocalProcessTerminalView?
        private var hasStarted = false

        init(processConfig: ClaudeProcessConfig) {
            self.processConfig = processConfig
        }

        func startIfNeeded(_ view: LocalProcessTerminalView) {
            guard !hasStarted else { return }
            hasStarted = true
            self.view = view
            view.startProcess(
                executable: processConfig.executablePath,
                args: processConfig.arguments,
                environment: processConfig.environment.map { "\($0.key)=\($0.value)" },
                execName: nil,
                currentDirectory: processConfig.workingDirectory
            )
        }
    }
}
