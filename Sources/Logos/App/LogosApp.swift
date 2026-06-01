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
    @State private var accountManager = LogosApp.makeAccountManager()
    @State private var workspace = WorkspaceModel()
    @State private var pdfPreview = PDFLivePreviewModel()
    @State private var generalSettings = GeneralSettings()
    @State private var advancedSettings = AdvancedSettings()

    /// Production: the real keychain-backed manager on `.standard`. Under
    /// `--ui-testing` (#27): a volatile UserDefaults suite cleared each launch +
    /// optional `--seed-accounts <csv>` stub accounts, so XCUITest flows get a
    /// renderable terminal + switchable accounts WITHOUT touching the keychain or
    /// the dev machine's real account list. The args never appear in production.
    @MainActor
    private static func makeAccountManager() -> AccountManager {
        let args = CommandLine.arguments
        guard args.contains("--ui-testing") else {
            return AccountManager(store: KeychainCredentialStore())
        }
        let suiteName = "app.getlogos.logos.uitesting"
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)  // clean slate each launch
        let mgr = AccountManager(store: KeychainCredentialStore(), defaults: suite)
        if let i = args.firstIndex(of: "--seed-accounts"), i + 1 < args.count {
            let labels = args[i + 1].split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if !labels.isEmpty { mgr.seedAccounts(labels) }
        }
        return mgr
    }

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
