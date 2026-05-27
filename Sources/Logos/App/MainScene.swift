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
                .frame(
                    minWidth: 900,
                    idealWidth: 1400,
                    minHeight: 600,
                    idealHeight: 900
                )
                .onAppear {
                    // Defer state changes one runloop tick to avoid
                    // AttributeGraph cycle warnings on initial render
                    Task { @MainActor in
                        FirstLaunchAccountImport.runIfNeeded(into: accountManager)
                        autoLoadWorkspaceIfNeeded()
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

    private func autoLoadWorkspaceIfNeeded() {
        if workspace.rootNode == nil {
            let cwd = FileManager.default.currentDirectoryPath
            try? workspace.openWorkspace(at: cwd)
        }
    }

    private func openWorkspaceViaDialog() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            try? workspace.openWorkspace(at: url.path)
        }
    }
}
