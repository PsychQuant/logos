import SwiftUI
import LogoSwitch
import LogosAccounts
import LogosUsage

@main
struct LogosApp: App {

    /// spec 2026-07-31: orderly gateway teardown at quit. A Process child is not
    /// reaped when its parent exits, so without this every gateway spawned during
    /// the session would outlive the app and keep holding its port.
    @NSApplicationDelegateAdaptor(LogosAppDelegate.self) private var appDelegate

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
    @State private var registryUsage = RegistryUsageModel(registry: LogosApp.sharedRegistry)
    /// #111: which accounts open windows are actually using. App-level so the single
    /// 帳號用量 window can see across every terminal window's per-window account (#42).
    @State private var accountWindowCensus = AccountWindowCensus()
    @State private var workspace = WorkspaceModel()
    @State private var pdfPreview = PDFLivePreviewModel()
    @State private var generalSettings = LogosApp.makeGeneralSettings()
    @State private var advancedSettings = LogosApp.makeAdvancedSettings()

    /// #104: ONE launch-time registry decision for both `sharedRegistry` and
    /// `makeAccountManager` (pure logic in `AccountBootstrap`). Volatile under
    /// `--ui-testing` (#27, pre-existing) and under app-hosted unit testing
    /// (#78 probe — new in #104, see `AccountBootstrap` for why the Track B
    /// test host must never bind the real registry).
    @MainActor
    private static let bootstrapMode: AccountBootstrapMode = AccountBootstrap.mode(
        arguments: CommandLine.arguments,
        isHostedUnitTesting: HostedTestEnvironment.isHostedUnitTesting())

    /// #67: the per-launch volatile accounts-index URL. Hoisted to a shared
    /// static (mirrors `uiTestingSettingsDirectory`) so both `sharedRegistry` —
    /// which writes `index.json` beneath it — and `makeAccountManager` — which
    /// under `--seed-remove-fails` chmods this file's parent dir read-only to arm
    /// the registry's designed persist-failure path — agree on ONE path. nil in
    /// production (`bootstrapMode == .production`). Computed once per launch.
    @MainActor
    private static let uiTestingAccountsIndexURL: URL? = {
        guard bootstrapMode == .volatile else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logos-uitesting-accounts-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent("index.json")
    }()

    /// Production: the shared-registry manager (accounts in the
    /// ~/.logos/accounts index file with one-time migration from this app's
    /// legacy UserDefaults data; active selection in `.standard` — no
    /// credential store; the #34 launcher model: claude owns each account's
    /// token under its own CLAUDE_CONFIG_DIR). Under `--ui-testing` (#27): a
    /// per-launch temp index file + a volatile UserDefaults suite cleared each
    /// launch + optional `--seed-accounts <csv>` stub accounts, so XCUITest
    /// flows get a renderable terminal + switchable accounts WITHOUT touching
    /// the dev machine's real account list. The args never appear in production.
    /// The ONE registry instance the whole app shares — AccountManager mutates
    /// it, the 帳號用量 window renders it, so the two can never disagree.
    /// Production: the shared index file (+ one-time legacy migration).
    /// `--ui-testing`: a per-launch temp index, never the real account list.
    @MainActor
    private static let sharedRegistry: AccountRegistry = {
        guard let indexURL = uiTestingAccountsIndexURL else {
            return AccountRegistry(legacyDefaults: .standard)
        }
        return AccountRegistry(indexFileURL: indexURL)
    }()

    @MainActor
    private static func makeAccountManager() -> AccountManager {
        let args = CommandLine.arguments
        guard bootstrapMode == .volatile else {
            let mgr = AccountManager(registry: sharedRegistry)
            // #50: one-shot startup GC of the account dirs orphaned by pre-#50 removes.
            // Runs HERE — during @State model construction, before any window/terminal
            // renders — so it completes BEFORE any claude spawn and never races a live
            // session writing its config dir. Conservative (only unregistered, no-config
            // dirs are reaped). Production only: the volatile path below uses a
            // per-launch temp registry, so real orphans must not be swept during a UI
            // test — nor by the Track B hosted test host (#104), which can now run
            // CONCURRENTLY with a live production Logos (own bundle id) and would
            // otherwise re-create the #80 registry race from outside the
            // LSMultipleInstancesProhibited fence.
            mgr.reapOrphanedDirectories()
            return mgr
        }
        let suiteName = "app.getlogos.logos.uitesting"
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)  // clean slate each launch
        let mgr = AccountManager(
            registry: sharedRegistry,
            store: UserDefaultsActiveAccountStore(defaults: suite))
        if let i = args.firstIndex(of: "--seed-accounts"), i + 1 < args.count {
            let labels = args[i + 1].split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if !labels.isEmpty { mgr.seedAccounts(labels) }
        }
        // #67: under `--seed-remove-fails`, arm the registry's DESIGNED persist-failure
        // path so a live delete → `remove()` fails → the `logos.account.delete.error`
        // caption surfaces (the Track-B E2E the harness previously couldn't force).
        // Placed AFTER seeding so the seed writes land first; then make the accounts-index
        // parent dir read-only (0o500). The next `.atomic` `save()` can't create its temp
        // file there → `save()` throws → `AccountRegistry.mutate` rolls back →
        // `registry.remove` throws → `AccountManager.remove` returns `false` (the real #57
        // rollback, not a stub). Bare flag matched by presence and passed AFTER the
        // `--seed-accounts <csv>` pair so it's never consumed as the csv value. Inert
        // without `--ui-testing` (the index URL is nil → skipped), same discipline as
        // `--seed-accounts`. Best-effort (`try?`): if no account was seeded the dir may
        // not exist, and a failed chmod simply leaves `remove()` succeeding.
        if args.contains("--seed-remove-fails"), let indexURL = uiTestingAccountsIndexURL {
            let accountsDir = indexURL.deletingLastPathComponent()
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: accountsDir.path)
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
            registryUsage: registryUsage,
            accountWindowCensus: accountWindowCensus,
            workspace: workspace,
            pdfPreview: pdfPreview,
            generalSettings: generalSettings,
            advancedSettings: advancedSettings
        )

        // merge-multistats-into-logos: display-only per-account plan-usage
        // window (opens from the Window menu). Shares the registry instance
        // with accountManager — see sharedRegistry.
        Window("帳號用量", id: "account-usage") {
            AccountUsageWindow()
                .environment(registryUsage)
                // Injected defensively, with NO current reader (#111 verify, requirements
                // + regression + logic lenses): the window's rows come from
                // `RegistryUsageModel`, and `isDefault` from `AccountUsageModel`, so
                // nothing here reads `AccountManager` today. It stays because adding an
                // `@Environment(AccountManager.self)` to this subtree later must not
                // silently re-introduce the #20 trap — the same reason the Settings scene
                // below injects the full set rather than only what it currently reads.
                .environment(accountManager)
                // #111: the 使用中 chip reads THIS — the live per-window census — not
                // `accountManager.activeAccountId`, which #42 demoted to a new-window
                // seed that an in-window switch never writes (so the chip never moved).
                .environment(accountWindowCensus)
        }
        .defaultSize(width: 480, height: 480)

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
                // #111: keeps the "full set" invariant this comment states — a new
                // app-level model must be injected here too, or a later
                // `@Environment(AccountWindowCensus.self)` read in any tab traps (#20).
                // (Pre-existing gap flagged at #111 verify, NOT introduced here:
                // `registryUsage` is likewise absent from this list — filed separately
                // rather than fixed in-scope.)
                .environment(accountWindowCensus)
        }
    }
}
