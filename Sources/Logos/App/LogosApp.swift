import SwiftUI

@main
struct LogosApp: App {

    // App-level ownership of the shared @Observable models (#20). Holding them
    // here (instead of inside MainScene) lets the same instances be injected into
    // BOTH the main WindowGroup and the Settings scene — a separate `Settings`
    // scene does not inherit a WindowGroup's environment, so reading any
    // @Environment(Type.self) inside SettingsWindow without injection traps
    // (EnvironmentValues.subscript.getter assertionFailure → SIGTRAP on open).
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
        MainScene(
            layout: layout,
            activityBar: activityBar,
            statusBar: statusBar,
            terminalConfig: terminalConfig,
            autoHandleEngine: autoHandleEngine,
            accountManager: accountManager,
            workspace: workspace,
            pdfPreview: pdfPreview,
            generalSettings: generalSettings,
            advancedSettings: advancedSettings
        )

        Settings {
            SettingsWindow()
                // Inject the SAME instances the WindowGroup uses. Full set (not just
                // the 5 the tabs currently read) so adding an @Environment to any tab
                // later can't silently re-introduce the #20 crash.
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
        }
    }
}
