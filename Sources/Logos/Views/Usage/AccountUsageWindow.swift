import SwiftUI
import LogosUsage
import LogoSwitch

/// 帳號用量 — per-account Claude plan-usage window (merge-multistats-into-logos).
///
/// Display-only registry consumer (design Decision 6): the rows come from the
/// SAME `AccountRegistry` instance `AccountManager` owns, so this window always
/// matches Settings → Accounts. It offers NO account switching, no login, and
/// no registry mutation — the only actions are refresh (on open, and the
/// toolbar button). Distinct from the status bar's per-session context-window
/// usage (#47): this is the plan/rate-limit quota per account.
struct AccountUsageWindow: View {
    @Environment(RegistryUsageModel.self) private var model
    /// #55 C3: read the launcher's active/seed selection to highlight the matching
    /// row. Bridge lives at the view layer only — `RegistryUsageModel` stays
    /// decoupled from `LogoSwitch`.
    @Environment(AccountManager.self) private var accountManager

    var body: some View {
        content
        .navigationTitle("帳號用量")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        model.load()
                        await model.refreshAll()
                    }
                } label: {
                    Label("重新整理", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            // Refresh on window open — reload picks up registry mutations made
            // in Settings since the last open.
            model.load()
            await model.refreshAll()
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    @ViewBuilder
    private var content: some View {
        if model.accounts.isEmpty {
            ContentUnavailableView(
                "尚無帳號",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("在 設定 → 帳號 新增帳號後，這裡會顯示各帳號的方案用量。"))
        } else {
            List(model.accounts) { account in
                UsageAccountRow(
                    account: account,
                    isActive: account.registryAccountId == accountManager.activeAccountId)
            }
        }
    }
}
