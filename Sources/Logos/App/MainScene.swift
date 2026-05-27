import SwiftUI

struct MainScene: Scene {

    @State private var layout = WindowLayoutState()
    @State private var activityBar = ActivityBarSelection()
    @State private var statusBar = StatusBarViewModel()
    @State private var terminalConfig = TerminalConfig()
    @State private var autoHandleEngine = AutoHandleEngine()
    @State private var accountManager = AccountManager(store: KeychainCredentialStore())

    var body: some Scene {
        WindowGroup("Logos") {
            MainView()
                .environment(layout)
                .environment(activityBar)
                .environment(statusBar)
                .environment(terminalConfig)
                .environment(autoHandleEngine)
                .environment(accountManager)
                .frame(
                    minWidth: 900,
                    idealWidth: 1400,
                    minHeight: 600,
                    idealHeight: 900
                )
                .onAppear {
                    FirstLaunchAccountImport.runIfNeeded(into: accountManager)
                }
        }
        .windowResizability(.contentSize)
    }
}
