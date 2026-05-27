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
                        FirstLaunchAccountImport.runIfNeeded(into: accountManager)
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
        guard FileManager.default.fileExists(atPath: lastPath) else {
            persistence.clear()
            return
        }
        await workspace.openWorkspaceAsync(at: lastPath)
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
