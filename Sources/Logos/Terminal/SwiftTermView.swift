import SwiftUI
import AppKit
import SwiftTerm

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

    func makeNSView(context: Context) -> TeedLocalProcessTerminalView {
        let view = TeedLocalProcessTerminalView(frame: .zero)
        TerminalThemeApplier.apply(config: config, to: view)
        view.onChunk = { [weak coord = context.coordinator] chunk in
            coord?.handleChunk(chunk)
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
            accountManager: accountManager
        )
    }

    /// Owns subprocess start. Gated by `hasStarted` so SwiftUI re-rendering
    /// the wrapper view doesn't spawn duplicate child processes.
    @MainActor
    final class Coordinator {
        let processConfig: ClaudeProcessConfig
        let engine: AutoHandleEngine
        let accountManager: AccountManager
        let parser: PatternParser
        weak var view: TeedLocalProcessTerminalView?
        private var hasStarted = false

        init(
            processConfig: ClaudeProcessConfig,
            engine: AutoHandleEngine,
            accountManager: AccountManager
        ) {
            self.processConfig = processConfig
            self.engine = engine
            self.accountManager = accountManager
            self.parser = PatternParser()
        }

        /// Called for each chunk the subprocess emits. Append to parser
        /// buffer, ask engine if any rule matches, inject response if so.
        func handleChunk(_ bytes: [UInt8]) {
            guard let text = String(bytes: bytes, encoding: .utf8) else { return }
            let buffered = parser.append(text)
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
                    // Could not write credentials — claude will likely fail to auth.
                    // For v1, log and let claude show its own auth-failed message.
                    // Future (sub-plan H): show in-app banner.
                    print("Logos: failed to materialize HOME for account \(account.id): \(error)")
                }
            }

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
