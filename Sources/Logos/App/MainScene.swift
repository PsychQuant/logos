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
        guard let lastPath = persistence.loadLastPath() else { return }
        // Validate path still exists before attempting load; stale entries
        // (workspace deleted / moved) clear persistence so user sees welcome
        // empty state on next launch instead of repeated load failures.
        //
        // Per #5: validation MUST run off MainActor. `FileManager.fileExists`
        // does a sync `stat(2)` which can block 5-30s for unreachable network
        // mounts, iCloud placeholder evictions, or recently-ejected USB drives
        // — same bug class as #2 (just smaller surface). `Self.pathExistsOffMain`
        // wraps the call in `Task.detached(.userInitiated)` so the launch path
        // stays responsive regardless of how slow the persisted path resolves.
        guard await Self.pathExistsOffMain(lastPath) else {
            persistence.clear()
            return
        }
        await workspace.openWorkspaceAsync(at: lastPath)
    }

    /// Reports whether `path` exists, evaluated off MainActor so a slow
    /// `stat(2)` (network mount unreachable, iCloud placeholder, ejected USB)
    /// doesn't block the UI thread. Per #5.
    static func pathExistsOffMain(_ path: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: path)
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
