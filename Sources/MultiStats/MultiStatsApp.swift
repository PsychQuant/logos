import SwiftUI
import AppKit
import MultiStatsCore

@main
struct MultiStatsApp: App {
    // A bare SwiftPM executable launches as an accessory process; the delegate
    // promotes it to a regular foreground app so the window appears and the
    // menu bar works when run via `swift run`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Claude 多帳號用量") {
            ContentView()
                .frame(minWidth: 460, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Root view: owns the accounts model, kicks off discovery + a first refresh on
/// appear, and offers a manual refresh in the toolbar.
struct ContentView: View {
    @State private var model = AccountsModel()

    var body: some View {
        NavigationStack {
            AccountList(accounts: model.accounts)
                .navigationTitle("Claude 用量")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.refreshAll() }
                        } label: {
                            Label("重新整理", systemImage: "arrow.clockwise")
                        }
                    }
                }
        }
        .task {
            model.load()
            await model.refreshAll()
        }
    }
}

/// The account list, factored out so it owns the empty-state branch and keeps
/// the row builder unary (one `AccountRow` per element, keyed on the account id).
struct AccountList: View {
    let accounts: [AccountUsageModel]

    var body: some View {
        if accounts.isEmpty {
            ContentUnavailableView(
                "找不到帳號",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("找不到任何 Claude Code 帳號設定（~/.claude 或 ~/.logos/accounts）。"))
        } else {
            List(accounts) { account in
                AccountRow(account: account)
            }
        }
    }
}
