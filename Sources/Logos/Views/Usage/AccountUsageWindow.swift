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
    /// #111: which accounts open windows are ACTUALLY using, and how many each.
    ///
    /// The 使用中 chip used to compare against `accountManager.activeAccountId`, which
    /// #42 demoted to *the seed for newly-opened windows*: an in-window switch writes
    /// `WindowAccountSelection` and deliberately never touches the global id, so the chip
    /// was bound to a field the switch could not write and never moved. The census is the
    /// only cross-window view of that per-window value.
    @Environment(AccountWindowCensus.self) private var census
    /// #112: the persisted row order. Lives on `GeneralSettings` rather than a new
    /// app-level model — see the note there.
    @Environment(GeneralSettings.self) private var generalSettings

    /// #112: rows in the user's chosen order.
    ///
    /// `now` is read HERE, once per body evaluation, and handed to the pure sort — the sort
    /// never reads the clock itself, so it stays testable and the list cannot silently
    /// reorder while the user is looking at it (it re-derives on refresh / reopen, which is
    /// when the underlying numbers change anyway).
    private var orderedAccounts: [AccountUsageModel] {
        UsageSorting.sorted(
            model.accounts,
            by: generalSettings.usageSortOrder,
            now: Date(),
            state: \.state)
    }

    var body: some View {
        content
        .navigationTitle("帳號用量")
        .toolbar {
            // #112: a Picker rather than a toggle — the ruling chose one of three candidate
            // urgency algorithms and the issue floated a fourth ordering, so the control has
            // to survive a third entry without changing shape.
            ToolbarItem(placement: .primaryAction) {
                Picker("排序", selection: Binding(
                    get: { generalSettings.usageSortOrder },
                    set: { generalSettings.usageSortOrder = $0 }
                )) {
                    ForEach(UsageSortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("logos.usage.sortOrder")
                .help("帳號順序＝registry 順序，位置固定可預期。重置緊迫度＝以「剩餘額度 ÷ 還要等多久重置」排序，每小時可用額度最少的排前面；一個帳號有多個每週視窗時取最緊迫的那一個。")
            }
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
            List(orderedAccounts) { account in
                UsageAccountRow(
                    account: account,
                    activeWindowCount: census.windowCount(for: account.registryAccountId))
            }
        }
    }
}
