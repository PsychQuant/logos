import SwiftUI
import AppKit

struct MainScene: Scene {

    @State private var layout = WindowLayoutState()
    @State private var activityBar = ActivityBarSelection()
    @State private var statusBar = StatusBarViewModel()
    @State private var terminalConfig = TerminalConfig()
    @State private var autoHandleEngine = AutoHandleEngine()
    @State private var accountManager = AccountManager(store: KeychainCredentialStore())
    @State private var workspace = WorkspaceModel()
    @State private var pdfPreview = PDFLivePreviewModel()
    @State private var generalSettings = GeneralSettings()
    @State private var advancedSettings = AdvancedSettings()

    var body: some Scene {
        WindowGroup("Logos") {
            MainView()
                .environment(layout)
                .environment(activityBar)
                .environment(statusBar)
                .environment(terminalConfig)
                .environment(autoHandleEngine)
                .environment(accountManager)
                .environment(workspace)
                .environment(pdfPreview)
                .environment(generalSettings)
                .environment(advancedSettings)
                .frame(
                    minWidth: 900,
                    idealWidth: 1400,
                    minHeight: 600,
                    idealHeight: 900
                )
                .preferredColorScheme(generalSettings.theme.colorScheme)
                .onAppear {
                    Task { @MainActor in
                        // E.2 behavior change (per #3): no auto-import on launch.
                        // Touching the system Claude keychain entry from
                        // MainActor onAppear triggers macOS's "找不到鑰匙圈來
                        // 儲存「<user>」" fallback dialog on macOS 26 for
                        // unsandboxed Developer-ID apps. The user-facing flow
                        // is now: open Settings → Accounts → "Capture current
                        // login" button (existing UI in AccountSwitcherSheet).
                        await autoLoadWorkspaceIfNeeded()
                    }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Workspace…") {
                    openWorkspaceViaDialog()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func autoLoadWorkspaceIfNeeded() async {
        guard workspace.rootNode == nil else { return }
        let persistence = WorkspacePersistence()
        let persisted = persistence.loadLastPath()

        // Resolve which workspace to auto-load at launch (#8). Precedence:
        // explicit `--workspace <path>` arg → persisted → guarded cwd → welcome.
        // Both arg and cwd are routed through WorkspaceLoader.isSystemPath so a
        // system path (notably cwd=`/` on GUI launch) is refused — structurally
        // cannot re-introduce #2's cwd=`/` walk.
        guard let target = Self.resolveLaunchWorkspace(
            arguments: CommandLine.arguments,
            persisted: persisted,
            cwd: FileManager.default.currentDirectoryPath,
            isSystem: { WorkspaceLoader.isSystemPath(WorkspaceLoader.canonical($0)) }
        ) else { return }

        // Validate the chosen path is an existing directory, off MainActor (#5/#9).
        guard await Self.directoryExistsOffMain(target) else {
            // Only the persisted path is cleared on a stale/invalid result — an
            // invalid arg/cwd shouldn't nuke a (different) persisted workspace.
            if target == persisted { persistence.clear() }
            return
        }
        await workspace.openWorkspaceAsync(at: target)
    }

    /// Pure precedence resolver for the launch workspace (#8). Injected inputs
    /// + `isSystem` predicate keep it deterministically testable without reading
    /// the real `CommandLine` / cwd. Returns nil → welcome state.
    static func resolveLaunchWorkspace(
        arguments: [String],
        persisted: String?,
        cwd: String,
        isSystem: (String) -> Bool
    ) -> String? {
        // 1. Explicit --workspace arg (user's clear intent) — refused if system.
        if let arg = parseWorkspaceArgument(arguments), !isSystem(arg) {
            return arg
        }
        // 2. Persisted workspace (current default behavior).
        if let persisted { return persisted }
        // 3. Guarded cwd fallback — only when no arg + no persisted. cwd=`/`
        //    (GUI launch) and system paths are refused → cannot re-introduce #2.
        if !isSystem(cwd) {
            return cwd
        }
        return nil
    }

    /// Extracts the value of `--workspace <path>` / `--workspace=<path>` from
    /// launch arguments. No positional support: macOS injects positional and
    /// `-psn_*` args on GUI launch, which a positional reader would misread (#8 D1).
    static func parseWorkspaceArgument(_ args: [String]) -> String? {
        var i = 1   // skip arg[0] (binary path)
        while i < args.count {
            let a = args[i]
            if a == "--workspace", i + 1 < args.count {
                return args[i + 1]
            }
            if a.hasPrefix("--workspace=") {
                return String(a.dropFirst("--workspace=".count))
            }
            i += 1
        }
        return nil
    }

    /// Reports whether `path` exists **and is a directory**, evaluated off
    /// MainActor so a slow `stat(2)` (network mount unreachable, iCloud
    /// placeholder, ejected USB) doesn't block the UI thread (#5). The
    /// directory check guards against a persisted path that became a file (#9).
    static func directoryExistsOffMain(_ path: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return exists && isDir.boolValue
        }.value
    }

    private func openWorkspaceViaDialog() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await workspace.openWorkspaceAsync(at: url.path)
            }
        }
    }
}
