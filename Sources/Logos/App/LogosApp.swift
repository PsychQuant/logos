import SwiftUI
import LogoSwitch
import LogosAccounts

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
    @State private var generalSettings = LogosApp.makeGeneralSettings()
    @State private var advancedSettings = LogosApp.makeAdvancedSettings()

    /// Production: the shared-registry manager (accounts in the
    /// ~/.logos/accounts index file with one-time migration from this app's
    /// legacy UserDefaults data; active selection in `.standard` — no
    /// credential store; the #34 launcher model: claude owns each account's
    /// token under its own CLAUDE_CONFIG_DIR). Under `--ui-testing` (#27): a
    /// per-launch temp index file + a volatile UserDefaults suite cleared each
    /// launch + optional `--seed-accounts <csv>` stub accounts, so XCUITest
    /// flows get a renderable terminal + switchable accounts WITHOUT touching
    /// the dev machine's real account list. The args never appear in production.
    @MainActor
    private static func makeAccountManager() -> AccountManager {
        let args = CommandLine.arguments
        guard args.contains("--ui-testing") else {
            return AccountManager()
        }
        let suiteName = "app.getlogos.logos.uitesting"
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)  // clean slate each launch
        let indexURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logos-uitesting-accounts-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent("index.json")
        let mgr = AccountManager(
            registry: AccountRegistry(indexFileURL: indexURL),
            store: UserDefaultsActiveAccountStore(defaults: suite))
        if let i = args.firstIndex(of: "--seed-accounts"), i + 1 < args.count {
            let labels = args[i + 1].split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if !labels.isEmpty { mgr.seedAccounts(labels) }
        }
        return mgr
    }

    /// #27: under `--ui-testing`, settings persist to a per-launch temp directory
    /// instead of `~/Library/Application Support/Logos/`, so a UI test (e.g. the
    /// dangerous-mode toggle flow) NEVER mutates the user's real `advanced.json`
    /// (a crash mid-flow could otherwise leave `dangerouslySkipPermissions = true`
    /// in production). nil → production default dir. Computed once per launch.
    private static let uiTestingSettingsDirectory: String? = {
        guard CommandLine.arguments.contains("--ui-testing") else { return nil }
        let dir = NSTemporaryDirectory()
            + "logos-uitesting-settings-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: dir)  // clean slate each launch
        return dir
    }()

    @MainActor
    private static func makeAdvancedSettings() -> AdvancedSettings {
        guard let dir = uiTestingSettingsDirectory else { return AdvancedSettings() }
        return AdvancedSettings(persistence: SettingsPersistence(directory: dir))
    }

    @MainActor
    private static func makeGeneralSettings() -> GeneralSettings {
        guard let dir = uiTestingSettingsDirectory else { return GeneralSettings() }
        return GeneralSettings(persistence: SettingsPersistence(directory: dir))
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
