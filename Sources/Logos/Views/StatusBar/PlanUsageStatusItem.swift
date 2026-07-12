import SwiftUI
import LogosUsage
import LogoSwitch

/// #90: the 5-hour plan-usage (rate-limit) HUD segment — a green→yellow→red fill bar
/// for the ACTIVE account's `five_hour` window from `RegistryUsageModel` (#51/#52/#53),
/// the same plan-budget the 帳號用量 window renders. Distinct from the context bar
/// (#47), which is this window's per-session context occupancy.
///
/// The active account is bridged through `AccountManager.activeAccountId`, exactly as
/// `AccountUsageWindow` matches `account.registryAccountId == accountManager.activeAccountId`.
/// Refresh is event-driven — on appear and on account switch — and coalesces with the
/// usage window's own refresh through the shared `RefreshCoalescer` (#51), so a status-bar
/// refresh never stacks a second keychain dialog.
struct PlanUsageStatusItem: View {
    @Environment(RegistryUsageModel.self) private var registryUsage
    @Environment(AccountManager.self) private var accountManager

    /// The active account's five-hour window, once its fetch has loaded. `nil` while the
    /// account is unloaded / errored / has no such window — the bar then shows an empty
    /// placeholder rather than a stale or full reading.
    private var activeWindow: UsageWindow? {
        guard let activeId = accountManager.activeAccountId,
              let model = registryUsage.accounts.first(where: { $0.registryAccountId == activeId }),
              case let .loaded(usage, _) = model.state
        else { return nil }
        return usage.windows.first { $0.id == "five_hour" }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hourglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Consumed fraction = utilization/100; nil (unloaded) → empty bar.
            HUDProgressBar(fraction: (activeWindow?.utilization ?? 0) / 100)
            Text(label)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("Active account's 5-hour plan usage (rate-limit budget), from the same source as the 帳號用量 window. Green under 70% used, yellow 70–90%, red above 90%. Refreshes on open and on account switch.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan usage \(label)")
        .accessibilityIdentifier("logos.statusbar.planUsage")
        .task {
            // Consumer, not discoverer: populate the rows once (they're shared with the
            // usage window), then fetch. `refreshAll()` coalesces with any concurrent
            // refresh — one fetch, one keychain dialog (#51).
            if registryUsage.accounts.isEmpty { registryUsage.load() }
            await registryUsage.refreshAll()
        }
        .onChange(of: accountManager.activeAccountId) {
            // The active account moved — re-fetch so the bar reflects the now-active plan
            // budget. Event-driven only; no periodic poll (the budget changes slowly and
            // the endpoint is rate-limited).
            Task { await registryUsage.refreshAll() }
        }
    }

    /// `5h · 45%` used, or `5h · —` before the active account's window has loaded.
    private var label: String {
        guard let window = activeWindow else { return "5h · —" }
        return "5h · \(Int(window.utilization.rounded()))%"
    }
}
